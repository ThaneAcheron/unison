module Unison.Term where

import Array
import Array (Array)
import Dict
import Dict (Dict)
import Json
import Maybe (isJust, maybe)
import Elmz.Maybe as EM
import Set
import Set (Set)
import String
import Graphics.Element as E
import Graphics.Input (Handle, hoverable)
import Text(..)
import Unison.Layout (Layout)
import Unison.Layout as L
import Unison.Styles as Styles
import Unison.Styles (codeText)
import Unison.Hash (Hash)
import Unison.Hash as H
import Unison.Jsonify as J
import Unison.Jsonify (Jsonify)
import Unison.Metadata as Metadata
import Unison.Metadata (Metadata, Fixity)
import Unison.Parser as P
import Unison.Parser (Parser)
import Unison.Path (..)
import Unison.Path as Path
import Unison.Var (I)
import Unison.Var as V
import Unison.Type as T
type Path = Path.Path -- to avoid conflict with Graphics.Collage.Path

data Literal
  = Number Float
  | Str String
  | Vector (Array Term)
  | Builtin String

data Term
  = Var I
  | Lit Literal
  | Con Hash
  | Ref Hash
  | App Term Term
  | Ann Term T.Type
  | Lam I Term

todo : a
todo = todo

{-| Returns the subterm at the given path, if the path is valid. -}
at : Path -> Term -> Maybe Term
at p e = case (p,e) of
  ([], e) -> Just e
  (Fn :: t, App f _) -> at t f
  (Arg :: t, App _ arg) -> at t arg
  (Body :: t, Lam _ body) -> at t body
  (Index i :: t, Lit (Vector es)) -> case Array.get i es of
    Just e -> at t e
    _ -> Nothing
  _ -> Nothing

{-| Returns `True` if the path points to a valid subterm -}
valid : Term -> Path -> Bool
valid e p = isJust (at p e)

{-| Move path to point to leftmost child, or return `p` unmodified
    if no such child exists. -}
down : Term -> Path -> Path
down e p =
  let apps e = case e of
        App f x -> apps f + 1
        _ -> 1
      go e = case e of
        App f x -> p `append` repeat (apps f) Fn
        Lit (Vector es) -> if Array.length es == 0 then p else p `snoc` Index 0
        Lam _ _ -> p `snoc` Body
        _ -> p
  in maybe p go (at p e)

{-| Move path to point to parent node in "logical" layout. -}
up : Path -> Path
up p =
  let go p = case p of
    [] -> []
    _ :: Arg :: tl -> reverse (Arg :: tl)
    Fn :: tl -> go tl
    Arg :: tl -> go tl
    _ :: tl -> reverse tl -- Index or Body
  in go (reverse p)

{-| Move the path to its immediate sibling to the right,
    or return `p` unmodified if no such sibling exists.  -}
siblingR : Term -> Path -> Path
siblingR e p =
  let p2 = increment (valid e) p
  in if decrement (valid e) p2 == p then p2
     else p

{-| Move the path to its immediate sibling to the right,
    or return `p` unmodified if no such sibling exists.  -}
siblingL : Term -> Path -> Path
siblingL e p =
  let p2 = decrement (valid e) p
  in if increment (valid e) p2 == p then p2
     else p

type L = { hash : Hash, path : Path, selectable : Bool }

layout : Term -- term to render
      -> { key            : Hash
         , availableWidth : Int
         , metadata       : Hash -> Metadata
         , overrides      : Path -> Maybe (Layout L) }
      -> Layout L
layout expr env =
  let
    md = env.metadata env.key
    tag path = { path = path, hash = env.key, selectable = True }
    utag path = { path = path, hash = env.key, selectable = False }
    space = codeText " "
    spaces n =
      if n <= 0 then empty else codeText (String.padLeft (n*2) ' ' "")
    space2 = codeText "  "
    indentWidth = E.widthOf space2
    paren : Bool -> { path : Path, term : Term }
         -> Layout { hash : Hash, path : Path, selectable : Bool }
         -> Layout { hash : Hash, path : Path, selectable : Bool }
    paren parenthesize cur e =
      if parenthesize
      then let t = tag cur.path
               opening = L.embed t (codeText "(")
               closing = L.embed t (codeText ")")
               botY = L.heightOf e - L.heightOf closing
               topOpen = L.container t (L.widthOf opening) (L.heightOf e) (L.Pt 0 0) opening
               bottomClose = L.container t (L.widthOf opening) (L.heightOf e) (L.Pt 0 botY) closing
           in L.horizontal t [topOpen, e, bottomClose]
      else e

    go : Bool
      -> Int
      -> Int
      -> { path : Path, term : Term }
      -> Layout { hash : Hash, path : Path, selectable : Bool }
    go allowBreak ambientPrec availableWidth cur =
      case env.overrides cur.path of
        Just l -> l
        Nothing -> case cur.term of
          Var n -> codeText (Metadata.resolveLocal md cur.path n).name |> L.embed (tag cur.path)
          Ref h -> codeText (Metadata.firstName h (env.metadata h)) |> L.embed (tag cur.path)
          Con h -> codeText (Metadata.firstName h (env.metadata h)) |> L.embed (tag cur.path)
          Lit (Number n) -> Styles.numericLiteral (String.show n) |> L.embed (tag cur.path)
          Lit (Str s) -> Styles.stringLiteral ("\"" ++ s ++ "\"") |> L.embed (tag cur.path)
          App (App (Lit (Builtin "cell")) x) y -> todo
          App (App (Lit (Builtin "panel")) x) y -> todo -- need to convert x to a Term -> Term
          _ -> let space' = L.embed (tag cur.path) space in
          case break env.key env.metadata cur.path cur.term of
            Prefix f args ->
              let f' = go False 9 availableWidth f
                  lines = f' :: map (go False 10 0) args
                  unbroken = L.intersperseHorizontal space' lines
                          |> paren (ambientPrec > 9) cur
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else let args' = map (go True 10 (availableWidth - L.widthOf f' - L.widthOf space')) args
                               |> L.vertical (tag cur.path)
                      in L.intersperseHorizontal space' [f',args']
                      |> paren (ambientPrec > 9) cur
            Operators leftAssoc prec hd tl ->
              let f (op,r) l = L.intersperseHorizontal space' [ l, go False 10 0 op, go False rprec 0 r ]
                  unbroken = foldl f (go False lprec 0 hd) tl
                          |> paren (ambientPrec > 9) cur
                  lprec = if leftAssoc then prec else 1+prec
                  rprec = if leftAssoc then 1+prec else prec
                  bf (op,r) l =
                    let op' = go False 10 0 op
                        remWidth = availableWidth - L.widthOf op' - L.widthOf space'
                    in L.above (tag cur.path) l <|
                       L.intersperseHorizontal space' [op', go True rprec remWidth r ]
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else foldl bf (go True lprec (availableWidth - indentWidth) hd) tl
                      |> paren (ambientPrec > 9) cur
            Lambda args body ->
              let argLayout = map (go False 0 0) args ++ [L.embed (tag cur.path) (codeText "→")]
                           |> L.intersperseHorizontal space'
                  unbroken = L.intersperseHorizontal space' [argLayout, go False 0 0 body]
                          |> paren (ambientPrec > 0) cur
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else L.above (tag cur.path)
                        argLayout
                        (L.horizontal (tag cur.path) [ space', space', go True 0 (availableWidth - indentWidth) body])
                      |> paren (ambientPrec > 0) cur
            Bracketed es ->
              let unbroken = Styles.cells (tag cur.path) (codeText "[]") (map (go False 0 0) es)
              in if not allowBreak || L.widthOf unbroken < availableWidth || length es < 2
              then unbroken
              else Styles.verticalCells (tag cur.path) (codeText "[]")
                                        (map (go True 0 (availableWidth - 4)) es) -- account for cell border
  in go True 0 env.availableWidth { path = [], term = expr }

data Break a
  = Prefix a [a]          -- `Prefix f [x,y,z] == f x y z`
  | Operators Bool Int a [(a,a)] -- `Operators False x [(+,y), (+,z)] == (x + y) + z`
                                 -- `Operators True x [(^,y), (^,z)] == x ^ (y ^ z)`
  | Bracketed [a]         -- `Bracketed [x,y,z] == [x,y,z]`
  | Lambda [a] a          -- `Lambda [x,y,z] e == x -> y -> z -> e`

break : Hash
    -> (Hash -> Metadata)
    -> Path
    -> Term
    -> Break { path : Path, term : Term }
break hash md path expr =
  let prefix f acc path = case f of
        App f arg -> prefix f ({ path = path `snoc` Arg, term = arg } :: acc) (path `snoc` Fn)
        _ -> Prefix { path = path, term = f } acc
      opsL o prec e acc path = case e of
        App (App op l) r ->
          if op == o
          then
            let hd = (
              { path = path `append` [Fn,Fn], term = op },
              { path = path `snoc` Arg, term = r })
            in opsL o prec l (hd :: acc) (path `append` [Fn,Arg])
          else Operators False prec { path = path, term = e} acc
        _ -> Operators False prec { path = path, term = e } acc
      opsR o prec e path = case e of
        App (App op l) r ->
          if op == o
          then case opsR o prec r (path `snoc` Arg) of
            Operators _ prec hd tl ->
              let tl' = ({ path = path `append` [Fn,Fn], term = op }, hd) :: tl
              in Operators True prec { path = path `append` [Fn,Arg], term = l} tl'
          else Operators True prec { path = path, term = e} []
        _ -> Operators True prec { path = path, term = e } []
  in case expr of
    Lit (Vector xs) -> xs
                    |> Array.indexedMap (\i a -> { path = path `snoc` Index i, term = a })
                    |> Array.toList
                    |> Bracketed
    App (App op l) r ->
      let sym = case op of
        Ref h -> Metadata.firstSymbol h (md h)
        Con h -> Metadata.firstSymbol h (md h)
        Var v -> Metadata.resolveLocal (md hash) path v
      in case sym.fixity of
        Metadata.Prefix -> prefix (App (App op l) r) [] path -- not an operator chain, fall back
        Metadata.InfixL -> opsL op sym.precedence (App (App op l) r) [] path -- left associated operator chain
        Metadata.InfixR -> opsR op sym.precedence (App (App op l) r) path
    Lam v body -> case body of -- audit this
      Lam _ _ -> case break hash md (path `snoc` Body) body of
        Lambda args body2 -> Lambda ({ path = path `snoc` Body, term = body } :: args) body2
        _ -> Lambda [{path = path, term = expr }] { path = path `snoc` Body, term = body }
      _ -> Lambda [{path = path, term = expr }] { path = path `snoc` Body, term = body }
    _ -> prefix expr [] path

parseLiteral : Parser Literal
parseLiteral = P.union' <| \t ->
  if | t == "Number" -> P.map Number P.number
     | t == "String" -> P.map Str P.string
     | t == "Builtin" -> P.map Builtin P.string
     | t == "Vector" -> P.map (Vector << Array.fromList) (P.array parseTerm)

jsonifyLiteral l = case l of
  Number n -> J.tag' "Number" J.number n
  Str s -> J.tag' "String" J.string s
  Vector es -> J.tag' "Vector" (J.contramap Array.toList (J.array jsonifyTerm)) es
  Builtin s -> J.tag' "Builtin" J.string s

parseTerm : Parser Term
parseTerm = P.union' <| \t ->
  if | t == "Var" -> P.map Var V.parse
     | t == "Lit" -> P.map Lit parseLiteral
     | t == "Con" -> P.map Con H.parse
     | t == "Ref" -> P.map Ref H.parse
     | t == "App" -> P.lift2 App parseTerm parseTerm
     | t == "Ann" -> P.lift2 Ann parseTerm T.parseType
     | t == "Lam" -> P.lift2 Lam V.parse parseTerm

jsonifyTerm : Jsonify Term
jsonifyTerm e = case e of
  Var v -> J.tag' "Var" V.jsonify v
  Lit l -> J.tag' "Lit" jsonifyLiteral l
  Con h -> J.tag' "Con" H.jsonify h
  Ref h -> J.tag' "Ref" H.jsonify h
  App f x -> J.tag' "App" (J.array jsonifyTerm) [f, x]
  Ann e t -> J.tag' "Ann" (J.tuple2 jsonifyTerm T.jsonifyType) (e, t)
  Lam n body -> J.tag' "Lam" (J.tuple2 V.jsonify jsonifyTerm) (n, body)

