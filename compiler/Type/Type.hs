module Type.Type where

import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.UnionFind.IO as UF
import SourceSyntax.PrettyPrint
import Text.PrettyPrint as P
import System.IO.Unsafe
import Control.Applicative ((<$>),(<*>))
import Control.Monad.State
import Data.Traversable (traverse)

data Term1 a
    = App1 a a
    | Fun1 a a
    | Var1 a
    | EmptyRecord1
    | Record1 (Map.Map String [a]) a
    deriving Show

data TermN a
    = VarN a
    | TermN (Term1 (TermN a))
    deriving Show

record fs rec = TermN (Record1 fs rec)

type SchemeName = String
type TypeName = String

data Constraint a b
    = CTrue
    | CEqual a a
    | CAnd [Constraint a b]
    | CLet [Scheme a b] (Constraint a b)
    | CInstance SchemeName a
    deriving Show

data Scheme a b = Scheme {
    rigidQuantifiers :: [b],
    flexibleQuantifiers :: [b],
    constraint :: Constraint a b,
    header :: Map.Map String a
} deriving Show

monoscheme headers = Scheme [] [] CTrue headers

data Descriptor = Descriptor {
    structure :: Maybe (Term1 Variable),
    rank :: Int,
    flex :: Flex,
    name :: Maybe TypeName,
    mark :: Int
} deriving Show

noRank = -1
outermostRank = 0 :: Int

data Flex = Rigid | Flexible | Constant
     deriving (Show, Eq)

type Variable = UF.Point Descriptor

type Type = TermN Variable
type TypeConstraint = Constraint Type Variable
type TypeScheme = Scheme Type Variable

infixl 8 /\

(/\) :: Constraint a b -> Constraint a b -> Constraint a b
a /\ b = CAnd [a,b]

(===) :: Type -> Type -> TypeConstraint
(===) = CEqual

(<?) :: SchemeName -> Type -> TypeConstraint
x <? t = CInstance x t

infixr 9 ==>
(==>) :: Type -> Type -> Type
a ==> b = TermN (Fun1 a b)

namedVar name = UF.fresh $ Descriptor {
    structure = Nothing,
    rank = noRank,
    flex = Constant,
    name = Just name,
    mark = 0
  }

flexibleVar = UF.fresh $ Descriptor {
    structure = Nothing,
    rank = noRank,
    flex = Flexible,
    name = Nothing,
    mark = 0
  }

rigidVar = UF.fresh $ Descriptor {
    structure = Nothing,
    rank = noRank,
    flex = Rigid,
    name = Nothing,
    mark = 0
  }

-- ex qs constraint == exists qs. constraint
ex :: [Variable] -> TypeConstraint -> TypeConstraint
ex fqs constraint = CLet [Scheme [] fqs constraint Map.empty] CTrue

-- fl qs constraint == forall qs. constraint
fl :: [Variable] -> TypeConstraint -> TypeConstraint
fl rqs constraint = CLet [Scheme rqs [] constraint Map.empty] CTrue

exists :: (Type -> IO TypeConstraint) -> IO TypeConstraint
exists f = do
  v <- flexibleVar
  ex [v] <$> f (VarN v)

instance Show a => Show (UF.Point a) where
  show point = unsafePerformIO $ fmap show (UF.descriptor point)

instance Pretty a => Pretty (UF.Point a) where
  pretty point = unsafePerformIO $ fmap pretty (UF.descriptor point)

instance Pretty a => Pretty (Term1 a) where
  pretty term =
    case term of
      App1 f x -> pretty f <+> pretty x
      Fun1 arg body -> pretty arg <+> P.text "->" <+> pretty body
      Var1 x -> pretty x
      EmptyRecord1 -> P.braces P.empty
      Record1 fields ext ->
          P.braces (pretty ext <+> P.text "|" <+> P.sep (P.punctuate P.comma prettyFields))
        where
          mkPretty f t = P.text f <+> P.text ":" <+> pretty t
          prettyFields = concatMap (\(f,ts) -> map (mkPretty f) ts) (Map.toList fields)

instance Pretty a => Pretty (TermN a) where
  pretty term =
    case term of
      VarN x -> pretty x
      TermN t1 -> pretty t1

instance Pretty Descriptor where
  pretty desc =
    case (structure desc, name desc) of
      (Just term, _) -> pretty term
      (_, Just name) -> P.text name
      _ -> P.text "?"

instance (Pretty a, Pretty b) => Pretty (Constraint a b) where
  pretty constraint =
    case constraint of
      CTrue -> P.text "True"
      CEqual a b -> pretty a <+> P.text "=" <+> pretty b
      CAnd [] -> P.text "True"

      CAnd (c:cs) ->
        P.parens . P.sep $ pretty c : (map (\c -> P.text "and" <+> pretty c) cs)

      CLet [Scheme [] fqs constraint header] CTrue | Map.null header ->
          P.hang binder 2 (pretty constraint)
        where
          binder = if null fqs then P.empty else
                     P.text "exists" <+> P.hsep (map pretty fqs) <> P.text "."

      CLet schemes constraint ->
        P.vcat [ P.hang (P.text "let") 4 (P.brackets . P.sep . P.punctuate P.comma $ map pretty schemes)
               , P.text "in " <+> pretty constraint ]

      CInstance name tipe ->
        P.text name <+> P.text "<" <+> pretty tipe

instance (Pretty a, Pretty b) => Pretty (Scheme a b) where
  pretty (Scheme rqs fqs constraint headers) =
      P.sep [ forall <+> frees <+> rigids, cs, headers' ]
    where
      forall = if Map.size headers + length rqs /= 0 then P.text "forall" else P.empty
      frees = P.hsep $ map pretty fqs
      rigids = if length rqs > 0 then P.braces . P.hsep $ map pretty rqs else empty
      cs = case constraint of
             CTrue -> P.empty
             CAnd [] -> P.empty
             _ -> P.brackets (pretty constraint)
      headers' = if Map.size headers > 0 then dict else P.empty
      dict = P.parens . P.sep . P.punctuate P.comma . map prettyPair $ Map.toList headers
      prettyPair (n,t) = P.text n <+> P.text ":" <+> pretty t


prettyNames constraint = do
    (_, rawVars) <- fold constraint [] getNames
    let vars = map head . List.group $ List.sort rawVars
        letters = map (:[]) ['a'..'z']
        suffix s = map (++s)
        allVars = letters ++ suffix "'" letters ++ concatMap (\n -> suffix (show n) letters) [0..]
        okayVars = filter (`notElem` vars) allVars
    fold constraint okayVars rename
  where
    getNames name vars =
      case name of
        Just var -> (name, var:vars)
        Nothing -> (name, vars)

    rename name vars =
      case name of
        Just var -> (name, vars)
        Nothing -> (Just (head vars), tail vars)

fold constraint initialState func =
    runStateT (prettyName constraint) initialState
  where
    prettyName constraint =
      case constraint of
        CTrue -> return CTrue
        CEqual a b -> CEqual <$> prettyTypeName a <*> prettyTypeName b
        CAnd cs -> CAnd <$> mapM prettyName cs
        CLet schemes c -> CLet <$> mapM prettySchemeName schemes <*> prettyName c
        CInstance name tipe -> CInstance name <$> prettyTypeName tipe

    prettySchemeName (Scheme rqs fqs c headers) =
       Scheme <$> mapM prettyVarName rqs <*> mapM prettyVarName fqs <*> prettyName c <*> return headers

    prettyVarName point = do
      state <- get
      put =<< do desc <- liftIO $ UF.descriptor point
                 let (name', state') = func (name desc) state
                 liftIO $ UF.setDescriptor point (desc { name = name' })
                 return state'
      return point

    prettyTypeName tipe =
      case tipe of
        VarN x -> VarN <$> prettyVarName x
        TermN term -> TermN <$> prettyTermName term

    prettyTermName term =
      case term of
        App1 a b -> App1 <$> prettyTypeName a <*> prettyTypeName b
        Fun1 a b -> Fun1 <$> prettyTypeName a <*> prettyTypeName b
        Var1 a -> Var1 <$> prettyTypeName a
        EmptyRecord1 -> return EmptyRecord1
        Record1 fields ext -> Record1 <$> fields' <*> prettyTypeName ext
          where
            fields' = traverse (mapM prettyTypeName) fields