{-# LANGUAGE DataKinds #-}

module Language.Haskell.Brittany
  ( parsePrintModule
  , pPrintModule
  , pPrintModuleAndCheck
   -- re-export from utils:
  , parseModule
  , parseModuleFromString
  )
where



#include "prelude.inc"

import qualified Language.Haskell.GHC.ExactPrint as ExactPrint
import qualified Language.Haskell.GHC.ExactPrint.Types as ExactPrint.Types
import qualified Language.Haskell.GHC.ExactPrint.Parsers as ExactPrint.Parsers

import qualified Data.Generics as SYB

import qualified Data.Text.Lazy.Builder as Text.Builder

import           Language.Haskell.Brittany.Types
import           Language.Haskell.Brittany.Config.Types
import           Language.Haskell.Brittany.LayouterBasics

import           Language.Haskell.Brittany.Layouters.Type
import           Language.Haskell.Brittany.Layouters.Decl
import           Language.Haskell.Brittany.Layouters.DataDecl
import           Language.Haskell.Brittany.Utils
import           Language.Haskell.Brittany.Backend
import           Language.Haskell.Brittany.BackendUtils
import           Language.Haskell.Brittany.ExactPrintUtils

import           Language.Haskell.Brittany.Transformations.Alt
import           Language.Haskell.Brittany.Transformations.Floating
import           Language.Haskell.Brittany.Transformations.Par
import           Language.Haskell.Brittany.Transformations.Columns
import           Language.Haskell.Brittany.Transformations.Indent

import qualified GHC as GHC hiding (parseModule)
import           ApiAnnotation ( AnnKeywordId(..) )
import           RdrName ( RdrName(..) )
import           GHC ( Located, runGhc, GenLocated(L), moduleNameString )
import           HsSyn

import           Data.HList.HList



-- LayoutErrors can be non-fatal warnings, thus both are returned instead
-- of an Either.
-- This should be cleaned up once it is clear what kinds of errors really
-- can occur.
pPrintModule
  :: Config
  -> ExactPrint.Types.Anns
  -> GHC.ParsedSource
  -> ([LayoutError], TextL.Text)
pPrintModule conf anns parsedModule =
  let
    ((out, errs), debugStrings) =
      runIdentity
        $ MultiRWSS.runMultiRWSTNil
        $ MultiRWSS.withMultiWriterAW
        $ MultiRWSS.withMultiWriterAW
        $ MultiRWSS.withMultiWriterW
        $ MultiRWSS.withMultiReader anns
        $ MultiRWSS.withMultiReader conf
        $ do
            traceIfDumpConf "bridoc annotations raw" _dconf_dump_annotations
              $ annsDoc anns
            ppModule parsedModule
    tracer =
      if Seq.null debugStrings
      then
        id
      else
        trace ("---- DEBUGMESSAGES ---- ")
          . foldr (seq . join trace) id debugStrings
  in
    tracer $ (errs, Text.Builder.toLazyText out)
  -- unless () $ do
  --   
  --   debugStrings `forM_` \s ->
  --     trace s $ return ()

-- | Additionally checks that the output compiles again, appending an error
-- if it does not.
pPrintModuleAndCheck
  :: Config
  -> ExactPrint.Types.Anns
  -> GHC.ParsedSource
  -> IO ([LayoutError], TextL.Text)
pPrintModuleAndCheck conf anns parsedModule = do
  let ghcOptions     = conf & _conf_forward & _options_ghc & runIdentity
  let (errs, output) = pPrintModule conf anns parsedModule
  parseResult <- parseModuleFromString ghcOptions
                                       "output"
                                       (\_ -> return $ Right ())
                                       (TextL.unpack output)
  let errs' = errs ++ case parseResult of
        Left{}  -> [LayoutErrorOutputCheck]
        Right{} -> []
  return (errs', output)


-- used for testing mostly, currently.
parsePrintModule :: Config -> String -> Text -> IO (Either String Text)
parsePrintModule conf filename input = do
  let inputStr = Text.unpack input
  parseResult <- ExactPrint.Parsers.parseModuleFromString filename inputStr
  case parseResult of
    Left  (_   , s           ) -> return $ Left $ "parsing error: " ++ s
    Right (anns, parsedModule) -> do
      (errs, ltext) <- pPrintModuleAndCheck conf anns parsedModule
      return $ if null errs
        then Right $ TextL.toStrict $ ltext
        else
          let
            errStrs = errs <&> \case
              LayoutErrorUnusedComment str -> str
              LayoutWarning            str -> str
              LayoutErrorUnknownNode str _ -> str
              LayoutErrorOutputCheck -> "Output is not syntactically valid."
          in
            Left $ "pretty printing error(s):\n" ++ List.unlines errStrs

-- this approach would for with there was a pure GHC.parseDynamicFilePragma.
-- Unfortunately that does not exist yet, so we cannot provide a nominally
-- pure interface.

-- parsePrintModule :: Text -> Either String Text
-- parsePrintModule input = do
--   let dflags = GHC.unsafeGlobalDynFlags
--   let fakeFileName = "SomeTestFakeFileName.hs"
--   let pragmaInfo = GHC.getOptions
--         dflags
--         (GHC.stringToStringBuffer $ Text.unpack input)
--         fakeFileName
--   (dflags1, _, _) <- GHC.parseDynamicFilePragma dflags pragmaInfo
--   let parseResult = ExactPrint.Parsers.parseWith
--         dflags1
--         fakeFileName
--         GHC.parseModule
--         inputStr
--   case parseResult of
--     Left (_, s) -> Left $ "parsing error: " ++ s
--     Right (anns, parsedModule) -> do
--       let (out, errs) = runIdentity
--                       $ runMultiRWSTNil
--                       $ Control.Monad.Trans.MultiRWS.Lazy.withMultiWriterAW
--                       $ Control.Monad.Trans.MultiRWS.Lazy.withMultiWriterW
--                       $ Control.Monad.Trans.MultiRWS.Lazy.withMultiReader anns
--                       $ ppModule parsedModule
--       if (not $ null errs)
--         then do
--           let errStrs = errs <&> \case
--                 LayoutErrorUnusedComment str -> str
--           Left $ "pretty printing error(s):\n" ++ List.unlines errStrs
--         else return $ TextL.toStrict $ Text.Builder.toLazyText out

ppModule :: Located (HsModule RdrName) -> PPM ()
ppModule lmod@(L loc m@(HsModule _name _exports _imports decls _ _)) = do
  let emptyModule = L loc m { hsmodDecls = [] }
  (anns', post) <- do
    anns <- mAsk
    -- evil partiality. but rather unlikely.
    return $ case Map.lookup (ExactPrint.Types.mkAnnKey lmod) anns of
      Nothing -> (anns, [])
      Just mAnn ->
        let modAnnsDp = ExactPrint.Types.annsDP mAnn
            isWhere (ExactPrint.Types.G AnnWhere) = True
            isWhere _                             = False
            isEof (ExactPrint.Types.G AnnEofPos) = True
            isEof _                              = False
            whereInd    = List.findIndex (isWhere . fst) modAnnsDp
            eofInd      = List.findIndex (isEof . fst) modAnnsDp
            (pre, post) = case (whereInd, eofInd) of
              (Nothing, Nothing) -> ([], modAnnsDp)
              (Just i , Nothing) -> List.splitAt (i + 1) modAnnsDp
              (Nothing, Just _i) -> ([], modAnnsDp)
              (Just i , Just j ) -> List.splitAt (min (i + 1) j) modAnnsDp
            mAnn'       = mAnn { ExactPrint.Types.annsDP = pre }
            anns'       = Map.insert (ExactPrint.Types.mkAnnKey lmod) mAnn' anns
        in  (anns', post)
  MultiRWSS.withMultiReader anns' $ processDefault emptyModule
  decls `forM_` ppDecl
  let finalComments = filter ( fst .> \case
                               ExactPrint.Types.AnnComment{} -> True
                               _                             -> False
                             )
                             post
  post `forM_` \case
    (ExactPrint.Types.AnnComment (ExactPrint.Types.Comment cmStr _ _), l) -> do
      ppmMoveToExactLoc l
      mTell $ Text.Builder.fromString cmStr
    (ExactPrint.Types.G AnnEofPos, (ExactPrint.Types.DP (eofX, eofY))) ->
      let folder acc (kw, ExactPrint.Types.DP (x, _)) = case kw of
            ExactPrint.Types.AnnComment cm
              | GHC.RealSrcSpan span <- ExactPrint.Types.commentIdentifier cm
              -> acc + x + GHC.srcSpanEndLine span - GHC.srcSpanStartLine span
            _ -> acc + x
          cmX = foldl' folder 0 finalComments
      in  ppmMoveToExactLoc $ ExactPrint.Types.DP (eofX - cmX, eofY)
    _ -> return ()

withTransformedAnns :: SYB.Data ast => ast -> PPM () -> PPM ()
withTransformedAnns ast m = do
  -- TODO: implement `local` for MultiReader/MultiRWS
  readers@(conf :+: anns :+: HNil) <- MultiRWSS.mGetRawR
  MultiRWSS.mPutRawR (conf :+: f anns :+: HNil)
  m
  MultiRWSS.mPutRawR readers
 where
  f anns =
    let ((), (annsBalanced, _), _) =
          ExactPrint.runTransform anns (commentAnnFixTransformGlob ast)
    in  annsBalanced

    
ppDecl :: LHsDecl RdrName -> PPM ()
ppDecl d@(L loc decl) = case decl of
  SigD sig  -> -- trace (_sigHead sig) $
               withTransformedAnns d $ do
    -- runLayouter $ Old.layoutSig (L loc sig)
    briDoc <- briDocMToPPM $ layoutSig (L loc sig)
    layoutBriDoc d briDoc
  ValD bind -> -- trace (_bindHead bind) $
               withTransformedAnns d $ do
    -- Old.layoutBind (L loc bind)
    briDoc <- briDocMToPPM $ do
      eitherNode <- layoutBind (L loc bind)
      case eitherNode of
        Left  ns -> docLines $ return <$> ns
        Right n  -> return n
    layoutBriDoc d briDoc
  TyClD (DataDecl name vars def _ _) -> withTransformedAnns d $ do
    briDoc <- briDocMToPPM $ layoutDataDecl d name vars def
    layoutBriDoc d briDoc
  _         -> briDocMToPPM (briDocByExactNoComment d) >>= layoutBriDoc d

_sigHead :: Sig RdrName -> String
_sigHead = \case
  TypeSig names _ ->
    "TypeSig " ++ intercalate "," (Text.unpack . lrdrNameToText <$> names)
  _ -> "unknown sig"

_bindHead :: HsBind RdrName -> String
_bindHead = \case
  FunBind fId _ _ _ [] -> "FunBind " ++ (Text.unpack $ lrdrNameToText $ fId)
  PatBind _pat _ _ _ ([], []) -> "PatBind smth"
  _ -> "unknown bind"



layoutBriDoc :: Data.Data.Data ast => ast -> BriDocNumbered -> PPM ()
layoutBriDoc ast briDoc = do
  -- first step: transform the briDoc.
  briDoc'                       <- MultiRWSS.withMultiStateS BDEmpty $ do
    traceIfDumpConf "bridoc raw" _dconf_dump_bridoc_raw
      $ briDocToDoc
      $ unwrapBriDocNumbered
      $ briDoc
    -- bridoc transformation: remove alts
    transformAlts briDoc >>= mSet
    mGet
      >>= traceIfDumpConf "bridoc post-alt" _dconf_dump_bridoc_simpl_alt
      .   briDocToDoc
    -- bridoc transformation: float stuff in
    mGet <&> transformSimplifyFloating >>= mSet
    mGet
      >>= traceIfDumpConf "bridoc post-floating"
                          _dconf_dump_bridoc_simpl_floating
      .   briDocToDoc
    -- bridoc transformation: par removal
    mGet <&> transformSimplifyPar >>= mSet
    mGet
      >>= traceIfDumpConf "bridoc post-par" _dconf_dump_bridoc_simpl_par
      .   briDocToDoc
    -- bridoc transformation: float stuff in
    mGet <&> transformSimplifyColumns >>= mSet
    mGet
      >>= traceIfDumpConf "bridoc post-columns" _dconf_dump_bridoc_simpl_columns
      .   briDocToDoc
    -- -- bridoc transformation: indent
    mGet <&> transformSimplifyIndent >>= mSet
    mGet
      >>= traceIfDumpConf "bridoc post-indent" _dconf_dump_bridoc_simpl_indent
      .   briDocToDoc
    mGet
      >>= traceIfDumpConf "bridoc final" _dconf_dump_bridoc_final
      .   briDocToDoc
    -- -- convert to Simple type
    -- simpl <- mGet <&> transformToSimple
    -- return simpl

  anns :: ExactPrint.Types.Anns <- mAsk
  let filteredAnns = filterAnns ast anns

  traceIfDumpConf "bridoc annotations filtered/transformed"
                  _dconf_dump_annotations
    $ annsDoc filteredAnns

  let state = LayoutState
        { _lstate_baseYs           = [0]
        , _lstate_curYOrAddNewline = Right 0 -- important that we use left here
                                             -- because moveToAnn stuff of the
                                             -- first node needs to do its
                                             -- thing properly.
        , _lstate_indLevels        = [0]
        , _lstate_indLevelLinger   = 0
        , _lstate_comments         = filteredAnns
        , _lstate_commentCol       = Nothing
        , _lstate_addSepSpace      = Nothing
        , _lstate_inhibitMTEL      = False
        }

  state' <- MultiRWSS.withMultiStateS state $ layoutBriDocM briDoc'

  let
    remainingComments =
      extractAllComments =<< Map.elems (_lstate_comments state')
  remainingComments
    `forM_` (mTell . (:[]) . LayoutErrorUnusedComment . show . fst)

  return $ ()
