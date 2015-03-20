module AST.Type
    ( Type(..), RawType, CanonicalType, PortType(..)
    , portTypeToType, fieldMap, recordOf, listOf, tupleOf
    , deepDealias, dealias
    , collectLambdas
    , prettyParens
    ) where

import Control.Applicative ((<$>), (<*>))
import Control.Arrow (second)
import Data.Binary
import qualified Data.Map as Map

import qualified AST.Variable as Var
import AST.PrettyPrint
import qualified AST.Helpers as Help
import Text.PrettyPrint as P


-- DEFINITION

data Type var
    = Lambda (Type var) (Type var)
    | Var String
    | Type var
    | App (Type var) [Type var]
    | Record [(String, Type var)] (Maybe (Type var))
    | Aliased Var.Canonical [(String, Type var)] (Type var)
    deriving (Eq,Show)


type RawType =
    Type Var.Raw


type CanonicalType =
    Type Var.Canonical


data PortType var
    = Inbound (Type var)
    | Internal (Type var)
    | Outbound (Type var)
    deriving (Show)


portTypeToType :: PortType Var.Canonical -> CanonicalType
portTypeToType portType =
  let makeType name tipe =
        App (Type (Var.fromModule ["Port"] name)) [tipe]
  in
  case portType of
    Inbound tipe -> makeType "InboundPort" tipe
    Internal tipe -> makeType "Port" tipe
    Outbound tipe -> makeType "OutboundPort" tipe


fieldMap :: [(String,a)] -> Map.Map String [a]
fieldMap fields =
  let add r (field,tipe) =
        Map.insertWith (++) field [tipe] r
  in
      foldl add Map.empty fields


recordOf :: [(String, Type var)] -> Type var
recordOf fields =
  Record fields Nothing


listOf :: RawType -> RawType
listOf tipe =
  App (Type (Var.Raw "List")) [tipe]


tupleOf :: [RawType] -> RawType
tupleOf types =
  let name = Var.Raw ("_Tuple" ++ show (length types))
  in
      App (Type name) types


-- DEALIASING

deepDealias :: Type v -> Type v
deepDealias tipe =
  let go = deepDealias in
  case tipe of
    Lambda a b ->
          Lambda (go a) (go b)

    Var _ ->
        tipe

    Record fields ext ->
        Record (map (second go) fields) (fmap go ext)

    Aliased _name args tipe' ->
        deepDealias (dealias args tipe')

    Type _ ->
        tipe

    App f args ->
        App (go f) (map go args)


dealias :: [(String, Type v)] -> Type v -> Type v
dealias args tipe =
    replace (Map.fromList args) tipe


replace :: Map.Map String (Type var) -> Type var -> Type var
replace typeTable t =
    let go = replace typeTable in
    case t of
      Lambda a b ->
          Lambda (go a) (go b)

      Var x ->
          Map.findWithDefault t x typeTable

      Record fields ext ->
          Record (map (second go) fields) (fmap go ext)

      Aliased original args t' ->
          let typeTable' = foldr Map.delete typeTable (map fst args)
          in
              Aliased original (map (second go) args) (replace typeTable' t')

      Type _ ->
          t

      App f args ->
          App (go f) (map go args)


-- PRETTY PRINTING

instance (Pretty var, Var.ToString var) => Pretty (PortType var) where
  pretty portType =
    case portType of
      Inbound tipe ->
          P.text "InboundPort" <+> pretty tipe

      Internal tipe ->
          P.text "Port" <+> pretty tipe

      Outbound tipe ->
          P.text "OutboundPort" <+> pretty tipe


instance (Var.ToString var, Pretty var) => Pretty (Type var) where
  pretty tipe =
    case tipe of
      Lambda _ _ ->
          P.sep [ t, P.sep (map (P.text "->" <+>) ts) ]
        where
          t:ts = map prettyLambda (collectLambdas tipe)
          prettyLambda t =
              case t of
                Lambda _ _ -> P.parens (pretty t)
                _ -> pretty t

      Var x ->
          P.text x

      Type var ->
          let v = Var.toString var
          in
              P.text (if v == "_Tuple0" then "()" else v)

      App f args ->
          case (f,args) of
            (Type name, _)
                | Help.isTuple (Var.toString name) ->
                    P.parens (P.sep (P.punctuate P.comma (map pretty args)))

            _ -> P.hang (pretty f) 2 (P.sep (map prettyParens args))

      Record _ _ ->
          case flattenRecord tipe of
            ([], Nothing) ->
                P.text "{}"

            (fields, Nothing) ->
                P.sep
                  [ P.cat (zipWith (<+>) (P.lbrace : repeat P.comma) (map prettyField fields))
                  , P.rbrace
                  ]

            (fields, Just x) ->
                P.hang
                    (P.lbrace <+> P.text x <+> P.text "|")
                    4
                    (P.sep
                      [ P.cat (zipWith (<+>) (P.space : repeat P.comma) (map prettyField fields))
                      , P.rbrace
                      ])
          where
            prettyField (field, tipe) =
                P.text field <+> P.text ":" <+> pretty tipe

      Aliased name [] t ->
          let t' = pretty t
          in
              if show t' `elem` ["Int", "Float", "String", "Char", "Bool"]
                then t'
                else pretty name

      Aliased name args _ ->
          P.hang (pretty name) 2 (P.sep (map (prettyParens . snd) args))


collectLambdas :: Type var -> [Type var]
collectLambdas tipe =
  case tipe of
    Lambda arg body ->
        arg : collectLambdas body

    _ ->
        [tipe]


prettyParens :: (Var.ToString var, Pretty var) => Type var -> Doc
prettyParens tipe =
    parensIf (needed tipe) (pretty tipe)
  where
    needed t =
      case t of
        Aliased _ [] _ -> False

        Aliased _ _ _ -> True

        Lambda _ _ -> True

        App (Type name) _
          | Help.isTuple (Var.toString name) ->
              False

        App t' [] -> needed t'

        App _ _ -> True

        _ -> False


flattenRecord :: Type var -> ( [(String, Type var)], Maybe String )
flattenRecord tipe =
  case tipe of
    Var x ->
        ([], Just x)

    Record fields Nothing ->
        (fields, Nothing)

    Record fields (Just ext) ->
        let (fields',ext') = flattenRecord ext
        in
            (fields' ++ fields, ext')

    Aliased _ _ tipe' ->
        flattenRecord tipe'

    _ ->
        error "Trying to flatten ill-formed record."


-- BINARY

instance Binary var => Binary (Type var) where
  put tipe =
      case tipe of
        Lambda t1 t2 ->
            putWord8 0 >> put t1 >> put t2

        Var x ->
            putWord8 1 >> put x

        Type name ->
            putWord8 2 >> put name

        App t1 t2 ->
            putWord8 3 >> put t1 >> put t2

        Record fs ext ->
            putWord8 4 >> put fs >> put ext

        Aliased var args t ->
            putWord8 5 >> put var >> put args >> put t

  get = do
      n <- getWord8
      case n of
        0 -> Lambda <$> get <*> get
        1 -> Var <$> get
        2 -> Type <$> get
        3 -> App <$> get <*> get
        4 -> Record <$> get <*> get
        5 -> Aliased <$> get <*> get <*> get
        _ -> error "Error reading a valid type from serialized string"
