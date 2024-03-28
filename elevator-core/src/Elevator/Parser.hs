{-# LANGUAGE OverloadedStrings #-}
module Elevator.Parser where

import Control.Applicative                (liftA2, (<**>))
import Control.Monad                      (void)
import Control.Monad.Combinators.Expr     qualified as CMCE
import Control.Monad.Combinators.NonEmpty qualified as CMCNE
import Data.Bifunctor                     (Bifunctor (first))
import Data.Functor                       (($>))
import Data.List                          (foldl')
import Data.List.NonEmpty                 (NonEmpty (..))
import Data.List.NonEmpty                 qualified as NE
import Data.Text                          (Text)
import Data.Text                          qualified as T
import Data.Void                          (Void)

import Text.Megaparsec
import Text.Megaparsec.Char               qualified as MPC
import Text.Megaparsec.Char.Lexer         qualified as MPCL

import Elevator.ModeSpec
import Elevator.Syntax

type ElParser = Parsec Void Text

readEitherCompleteFile :: (ElModeSpec m) => FilePath -> Text -> Either String (ElProgram m)
readEitherCompleteFile = runCompleteParser parseProgram

readEitherCompleteCommand :: (ElModeSpec m) => FilePath -> Text -> Either String (ElCommand m)
readEitherCompleteCommand = runCompleteParser parseCommand

runCompleteParser :: ElParser a -> FilePath -> Text -> Either String a
runCompleteParser p fp = first errorBundlePretty . parse (between MPC.space eof p) fp

parseCommand :: (ElModeSpec m) => ElParser (ElCommand m)
parseCommand = ComTop <$> parseTop <|> ComTerm <$> parseTerm

parseProgram :: (ElModeSpec m) => ElParser (ElProgram m)
parseProgram = ElProgram <$> many parseTop

parseTop :: (ElModeSpec m) => ElParser (ElTop m)
parseTop = (parseTyDefTop <|> parseTmDefTop) <?> "top-level definition"

parseTyDefTop :: (ElModeSpec m) => ElParser (ElTop m)
parseTyDefTop = do
  keyword "type"
  ys <- parened (sepBy parseLowerId (symbol "*" <?> "more type constructor arguments separated by \"*\"")) <|> option [] (pure <$> parseLowerId)
  x <- parseUpperId
  m <- parseMode
  symbol "="
  cs <- sepStartBy parseTyDefCons (symbol "|" <?> "more constructors separated by \"|\"")
  toplevelDelimiter
  pure $ TopTyDef ys x m cs

parseTmDefTop :: (ElModeSpec m) => ElParser (ElTop m)
parseTmDefTop = do
  (x, ps, ty) <- try $ do
    x <- parseLowerId
    ps <- many parseAtomicPattern
    symbol ":"
    ty <- parseType
    symbol "="
    pure (x, ps, ty)
  t <- parseTerm <?> "term definition"
  toplevelDelimiter
  pure . TopTmDef x ty $ foldr (`TmAmbiLam` Nothing) t ps

parseTyDefCons :: (ElModeSpec m) => ElParser (ElId, [ElType m])
parseTyDefCons =
  liftA2
    (,)
    parseUpperId
    (option [] (keyword "of" *> sepBy1 parseAppLikeType (symbol "*" <?> "more term constructor argument types separated by \"*\"")))
  <?> "type constructor definition"

parseTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseTerm = do
  choice
    [ parseLamTerm
    , parseMatchTerm
    , parseLetTerm
    , parseLoadTerm
    , parseIteTerm
    , parseBinOpTerm
    ]
  <**> parsePostAnn
  where
    parsePostAnn = option id (symbol ":" $> flip TmAnn <*> parseType)

parseLamTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseLamTerm = do
  keyword "fun"
  ps <- some parseParam
  symbol "->"
  t <- parseTerm
  pure $ foldr ($) t ps
  where
    parseParam :: (ElModeSpec m) => ElParser (ElTerm m -> ElTerm m)
    parseParam =
      parened (liftA2 TmAmbiLam parsePattern (optional (symbol ":" *> parseContextEntry)))
      <|> flip TmAmbiLam Nothing <$> parseAtomicPattern

parseMatchTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseMatchTerm = do
  keyword "match"
  t <- parseTerm
  mayTy <- optional (symbol ":" *> parseType)
  keyword "with"
  bs <- sepStartBy parseBranch (symbol "|" <?> "one more branch separated by \"|\"")
  keyword "end"
  pure $ TmMatch t mayTy bs

parseBranch :: (ElModeSpec m) => ElParser (ElBranch m)
parseBranch =
  liftA2
    (,)
    parsePattern
    (symbol "=>" *> parseTerm)

parsePattern :: (ElModeSpec m) => ElParser (ElPattern m)
parsePattern =
  choice
    [ keyword "load" $> PatLoad <*> parseAtomicPattern
    , liftA2 PatData parseUpperId parseDataArgPatterns
    , parseAtomicPattern 
    ]
  <?> "pattern"
  where
    parseDataArgPatterns =
      pure <$> parseUnitPattern
      <|> NE.toList <$> parseTupleLikePattern

parseAtomicPattern :: (ElModeSpec m) => ElParser (ElPattern m)
parseAtomicPattern =
  parseUnitPattern
  <|> wrapTupleLike <$> parseTupleLikePattern
  where
    wrapTupleLike (pat :| []) = pat
    wrapTupleLike pats = PatTuple (NE.toList pats)

parseTupleLikePattern :: (ElModeSpec m) => ElParser (NonEmpty (ElPattern m))
parseTupleLikePattern = parened (CMCNE.sepBy1 parsePattern (symbol ","))

parseUnitPattern :: (ElModeSpec m) => ElParser (ElPattern m)
parseUnitPattern =
  choice
    [ PatInt <$> lexeme MPCL.decimal
    , keyword "True" $> PatTrue
    , keyword "False" $> PatFalse
    , PatVar <$> parseLowerId
    , flip PatData [] <$> parseUpperId
    , symbol "_" $> PatWild
    ]

parseLetTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseLetTerm = do
  keyword "let"
  pat <- parsePattern
  mayTy <- optional (symbol ":" *> parseType)
  symbol "="
  t0 <- parseTerm
  keyword "in"
  t1 <- parseTerm
  keyword "end"
  pure $ TmMatch t0 mayTy [(pat, t1)]

parseLoadTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseLoadTerm = do
  keyword "load"
  pat <- parsePattern
  mayTy <- optional (symbol ":" *> parseType)
  symbol "="
  t0 <- parseTerm
  keyword "in"
  t1 <- parseTerm
  keyword "end"
  pure $ TmMatch t0 mayTy [(PatLoad pat, t1)]

parseIteTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseIteTerm = do
  keyword "if"
  t <- parseTerm
  keyword "then"
  t0 <- parseTerm
  keyword "else"
  TmIte t t0 <$> parseTerm

parseBinOpTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseBinOpTerm = CMCE.makeExprParser parseApplikeTerm table
  where
    table =
      [ [ CMCE.InfixL (symbol "*" $> TmBinOp OpMul <?> "operator \"*\"")
        , CMCE.InfixL (symbol "/" $> TmBinOp OpDiv <?> "operator \"/\"")
        , CMCE.InfixL (symbol "%" $> TmBinOp OpMod <?> "operator \"%\"")
        ]
      , [ CMCE.InfixL (symbol "+" $> TmBinOp OpAdd <?> "operator \"+\"")
        , CMCE.InfixL (symbol "-" $> TmBinOp OpSub <?> "operator \"-\"")
        ]
      , [ CMCE.InfixN (symbol "==" $> TmBinOp OpEq <?> "operator \"==\"")
        , CMCE.InfixN (symbol "/=" $> TmBinOp OpNe <?> "operator \"/=\"")
        , CMCE.InfixN (symbol "<=" $> TmBinOp OpLe <?> "operator \"<=\"")
        , CMCE.InfixN (symbol "<" $> TmBinOp OpLt <?> "operator \"<\"")
        , CMCE.InfixN (symbol ">=" $> TmBinOp OpGe <?> "operator \">=\"")
        , CMCE.InfixN (symbol ">" $> TmBinOp OpGt <?> "operator \">\"")
        ]
      ]

parseApplikeTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseApplikeTerm = parseShiftTerm <|> parseDataTerm <|> parseAppTerm

parseShiftTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseShiftTerm =
  choice
    [ parseSuspCommon TmSusp parseAtomicTerm parseTerm
    , parseForceCommon TmForce parseAtomicTerm
    , keyword "store" $> TmStore <*> parseAtomicTerm
    ]

parseDataTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseDataTerm = liftA2 TmData parseUpperId parseDataArgTerms
  where
    parseDataArgTerms =
      pure <$> parseUnitTerm
      <|> NE.toList <$> parseTupleLikeTerm

parseAppTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseAppTerm = liftA2 (Data.List.foldl' TmAmbiApp) parseAtomicTerm (many parseAtomicAmbi)

parseAtomicTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseAtomicTerm =
  parseUnitTerm
  <|> wrapTupleLike <$> parseTupleLikeTerm
  where
    wrapTupleLike (t :| []) = t
    wrapTupleLike ts = TmTuple (NE.toList ts)

parseTupleLikeTerm :: (ElModeSpec m) => ElParser (NonEmpty (ElTerm m))
parseTupleLikeTerm = parened (CMCNE.sepBy1 parseTerm (symbol ","))

parseUnitTerm :: (ElModeSpec m) => ElParser (ElTerm m)
parseUnitTerm =
  choice
    [ TmInt <$> lexeme MPCL.decimal
    , keyword "True" $> TmTrue
    , keyword "False" $> TmFalse
    , TmVar <$> parseLowerId
    , flip TmData [] <$> parseUpperId
    ]

parseAtomicAmbi :: (ElModeSpec m) => ElParser (ElAmbi m)
parseAtomicAmbi =
  choice
    [ try (AmCore <$> parseAtomicAmbiCore)
    , try (AmType <$> parseAtomicType)
    , AmTerm <$> parseAtomicTerm
    ]

parseAmbiCore :: (ElModeSpec m) => ElParser (ElAmbiCore m)
parseAmbiCore =
  choice
    [ parseSuspCommon AmSusp parseAtomicAmbiCore parseAmbiCore
    , parseForceCommon AmForce parseAmbiCore
    , parseAtomicAmbiCore
    ]

parseAtomicAmbiCore :: (ElModeSpec m) => ElParser (ElAmbiCore m)
parseAtomicAmbiCore = AmVar <$> parseLowerId <|> parened parseAmbiCore

parseKind :: (ElModeSpec m) => ElParser (ElKind m)
parseKind = liftA2 (foldr ($)) parseAtomicKind (many (keyword "Up" $> flip KiUp [] <*> parseMode))

parseAtomicKind :: (ElModeSpec m) => ElParser (ElKind m)
parseAtomicKind =
  choice
    [ keyword "Type" $> KiType <*> parseMode <?> "kind \"Type\""
    , parseContextualUpCommon KiUp parseKind
    , parened parseKind
    ]

parseType :: (ElModeSpec m) => ElParser (ElType m)
parseType =
  liftA2
    (flip (foldr ($)))
    (many (try (parseArgSpec <* symbol "->")))
    parseProdType
  where
    parseArgSpec =
      try (parened (liftA2 TyForall parseLowerId (symbol ":" *> parseKind)))
      <|> TyArr <$> parseProdType
      <?> "argument type"

parseProdType :: (ElModeSpec m) => ElParser (ElType m)
parseProdType = do
  neTys <- CMCNE.sepBy1 parseAppLikeType (symbol "*" <?> "one more product type item separated by \"*\"")
  case neTys of
    ty :| []  -> pure ty
    ty :| tys -> pure $ TyProd (ty:tys)

parseAppLikeType :: (ElModeSpec m) => ElParser (ElType m)
parseAppLikeType =
  parseDelayedType
  <|> parsePostType

parseDelayedType :: (ElModeSpec m) => ElParser (ElType m)
parseDelayedType =
  parseSuspCommon TySusp parseAtomicType parseType
  <|> parseForceCommon TyForce parseAtomicType

parsePostType :: (ElModeSpec m) => ElParser (ElType m)
parsePostType =
  liftA2 (foldr ($)) parseTupleArgDataType (many parsePostOp)
  where
    parsePostOp =
      choice
        [ keyword "Up" $> flip TyUp [] <*> parseMode <?> "Upshift of the type"
        , keyword "Down" $> TyDown <*> parseMode <?> "Downshift of the type"
        , flip (TyData . pure) <$> parseUpperId <?> "type constructor"
        ]

parseTupleArgDataType :: (ElModeSpec m) => ElParser (ElType m)
parseTupleArgDataType = do
  neTys <- pure <$> parseUnitType <|> parened (CMCNE.sepBy1 parseType (symbol ","))
  case neTys of
    ty :| [] -> option ty (TyData [ty] <$> parseUpperId <?> "type constructor")
    _ -> TyData (NE.toList neTys) <$> parseUpperId <?> "type constructor"

parseAtomicType :: (ElModeSpec m) => ElParser (ElType m)
parseAtomicType =
  parseUnitType
  <|> parened parseType

parseUnitType :: (ElModeSpec m) => ElParser (ElType m)
parseUnitType =
  choice
    [ keyword "Int" $> TyInt <*> parseMode
    , keyword "Bool" $> TyBool <*> parseMode
    , parseContextualUpCommon TyUp parseType
    , TyVar <$> parseLowerId <?> "type variable"
    , TyData [] <$> parseUpperId <?> "type constructor"
    ]

parseContextualUpCommon :: (ElModeSpec m) => (m -> ElContext m -> f m -> f m) -> ElParser (f m) -> ElParser (f m)
parseContextualUpCommon cons p = bracketed parseContextualCommon <*> (keyword "Up" *> parseMode)
  where
    parseContextualCommon = liftA2 (curry (flip (uncurry . cons))) parseContext (symbol "|-" *> p)

parseSuspCommon :: (ElModeSpec m) => (ElContextHat m -> f m -> f m) -> ElParser (f m) -> ElParser (f m) -> ElParser (f m)
parseSuspCommon cons ap p = keyword "susp" *> parseOpenItem
  where
    parseOpenItem = cons [] <$> try ap <|> parened (liftA2 cons parseContextHat (symbol "." *> p))

parseForceCommon :: (ElModeSpec m) => (f m -> ElSubst m -> f m) -> ElParser (f m) -> ElParser (f m)
parseForceCommon cons ap = keyword "force" *> liftA2 cons ap (option [] (symbol "with" *> parseSubst))

parseContext :: (ElModeSpec m) => ElParser (ElContext m)
parseContext =
  symbol "." *> many (symbol "," *> parseContextItem)
  <|> sepBy1 parseContextItem (symbol ",")
  <?> "context"
  where
    parseContextItem = liftA2 (,) parseLowerId (symbol ":" *> parseContextEntry)

parseContextEntry :: (ElModeSpec m) => ElParser (ElContextEntry m)
parseContextEntry =
  try (EntryOfKi <$> parseKind)
  <|> EntryOfTy <$> parseType

parseContextHat :: ElParser (ElContextHat m)
parseContextHat =
  symbol "." *> many (symbol "," *> parseLowerId)
  <|> sepBy1 parseLowerId (symbol ",")

parseSubst :: (ElModeSpec m) => ElParser (ElSubst m)
parseSubst = parened (sepBy parseTerm (symbol ","))

parseMode :: (ElModeSpec m) => ElParser m
parseMode = impl <?> "mode"
  where
    impl = do
      modeText <- angled (takeWhile1P (Just "mode") (/= '>'))
      case readModeEither (T.unpack modeText) of
        Right m -> pure m
        Left  e -> fail ("invalid mode: " <> e)

parseLowerId :: ElParser ElId
parseLowerId = elId <$> lowerIdentifier

parseUpperId :: ElParser ElId
parseUpperId = elId <$> upperIdentifier

------------------------------------------------------------
-- lexer-like combinators
------------------------------------------------------------

toplevelDelimiter :: ElParser ()
toplevelDelimiter = symbol ";;" <?> "top-level delimiter \";;\""

keywords :: [Text]
keywords =
  [ "Type"
  , "Up"
  , "Down"
  , "Int"
  , "Bool"
  , "store"
  , "load"
  , "in"
  , "susp"
  , "force"
  , "let"
  , "fun"
  , "if"
  , "then"
  , "else"
  , "True"
  , "False"
  , "match"
  , "with"
  , "end"
  , "type"
  , "of"
  ]

parened :: ElParser a -> ElParser a
parened = between (symbol "(") (symbol ")")

bracketed :: ElParser a -> ElParser a
bracketed = between (symbol "[") (symbol "]")

angled :: ElParser a -> ElParser a
angled = between (symbol "<") (symbol ">")

symbol :: Text -> ElParser ()
symbol txt = void (lexeme (MPC.string txt)) <?> ("symbol " <> show txt)

keyword :: Text -> ElParser ()
keyword txt
  | txt `elem` keywords = lexeme (MPC.string txt *> notFollowedBy restIdChar) <?> ("keyword " <> show txt)
  | otherwise           = error $ "Parser bug: unknown keyword " <> show txt

lowerIdentifier :: ElParser Text
lowerIdentifier = identifierOf MPC.lowerChar <?> "identifier starting with a lower-case letter"

upperIdentifier :: ElParser Text
upperIdentifier = identifierOf MPC.upperChar <?> "identifier starting with an upper-case letter"

identifierOf :: ElParser Char -> ElParser Text
identifierOf firstChar = identifierImpl
  where
    identifierImpl :: ElParser Text
    identifierImpl = try . withCondition (`notElem` keywords) ((<> "") . show) $
      lexeme ((T.pack .). (:) <$> firstChar <*> many restIdChar)

restIdChar :: ElParser Char
restIdChar = MPC.alphaNumChar <|> oneOf ("_'" :: String)

lexeme :: ElParser a -> ElParser a
lexeme p = p <* hidden MPC.space

withCondition :: (a -> Bool) -> (a -> String) -> ElParser a -> ElParser a
withCondition cond mkMsg p = do
  o <- getOffset
  r <- p
  if cond r
  then return r
  else region (setErrorOffset o) (fail (mkMsg r))

sepStartBy :: ElParser a -> ElParser sep -> ElParser [a]
sepStartBy p sep = option [] (sepStartBy1 p sep)

sepStartBy1 :: ElParser a -> ElParser sep -> ElParser [a]
sepStartBy1 p sep = optional sep *> sepBy1 p sep
