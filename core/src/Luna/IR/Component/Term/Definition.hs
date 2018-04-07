{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE UndecidableInstances #-}

module Luna.IR.Component.Term.Definition where

import Prologue

import qualified Control.Lens.TH                     as Lens
import qualified Control.Monad.State.Layered         as State
import qualified Data.Char                           as Char
import qualified Data.Map.Strict                     as Map
import qualified Data.Tag                            as Tag
import qualified Foreign.Storable.Deriving           as Storable
import qualified Foreign.Storable1.Deriving          as Storable1
import qualified Language.Haskell.TH                 as TH
import qualified Language.Haskell.TH.Builder         as State
import qualified Language.Haskell.TH.Syntax          as TH
import qualified Luna.IR.Component.Link              as Link
import qualified Luna.IR.Component.Link.TH           as Link
import qualified Luna.IR.Component.Term.Class        as Term
import qualified Luna.IR.Component.Term.Construction as Term
import qualified Luna.IR.Component.Term.Discovery    as Discovery
import qualified Luna.IR.Term.Format                 as Format
import qualified OCI.Data.Name                       as IR
import qualified OCI.IR.Layout                       as Layout
import qualified Type.Data.Map                       as TypeMap

import Data.Map.Strict              (Map)
import Luna.IR.Component.Link       (type (*-*), Link)
import Luna.IR.Component.Term.Layer (Model)

import Control.Monad.State.Layered  (StateT)
import Language.Haskell.TH          (Type (AppT, ConT))
import Language.Haskell.TH.Builder
import Luna.IR.Component.Term.Class (Term)
import OCI.IR.Layout                (Layout)



---------------------
-- === Helpers === --
---------------------

-- === Definition === --

-- | 'LinkTo' is a phantom helper type. It gets resolved to 'LinkTo__' during
--   code generation. It is used both as a short form for its expansion
--   (note that expansion refers to `self` which gets replaced by current term
--   type) as well as for smart constructor type inference.
data LinkTo   t a
type LinkTo__ t self a = Link (Layout.Get t a *-* Layout.Set Model self a)

-- | 'FieldCons' is a typeclass which unifies how fields of smart cons get
--   constructed. It's created only to make the generated code shorter and
--   more maintainable.
class Monad m => FieldCons t a m b where
    fieldCons :: Term t -> a -> m b


-- === Instances === --

instance Monad m => FieldCons t a m a where
    fieldCons _ = pure ; {-# INLINE fieldCons #-}

instance Link.Creator m => FieldCons t (Term a) m (Link b) where
    fieldCons self t = Layout.unsafeRelayout <$> Link.new t self ; {-# INLINE fieldCons #-}



type family   ExpandField self a
type instance ExpandField self IR.Name = IR.Name
type instance ExpandField self (LinkTo t a)
   = Link (Layout.Get t a *-* Layout.Set Model self a)


type family   FieldArg var field
type instance FieldArg var IR.Name      = IR.Name
type instance FieldArg var (LinkTo t a) = Term var

type family   AddToOutput var field        layout
type instance AddToOutput var IR.Name      layout = layout
type instance AddToOutput var (LinkTo t a) layout = Layout.SetMerge t var layout



---------------------------
-- === Term creation === --
---------------------------

-- | Term definition boilerplate
--
--   @
--       Term.define ''Format.Thunk [d|
--           data Unify a = Unify
--               { left  :: LinkTo Terms a
--               , right :: LinkTo Terms a
--               }
--        |]
--   @
--
--   Generates:
--
--   @
--       Tag.familyInstance "TermCons" "Unify"
--       data ConsUnify a = Unify
--           { __left  :: {-# UNPACK #-} !(ExpandField (LinkTo Terms Unify a))
--           , __right :: {-# UNPACK #-} !(ExpandField (LinkTo Terms Unify a))
--           } deriving (Show, Eq)
--       instance Discovery.IsTermTag Unify
--       type instance Format.Of      Unify     = Format.Phrase
--       type instance Term.TagToCons Unify     = ConsUnify
--       type instance Term.ConsToTag ConsUnify = Unify
--       makeLenses       ''ConsUnify
--       Storable.derive  ''ConsUnify
--       Storable1.derive ''ConsUnify
--       Link.discover    ''ConsUnify
--       type instance Format.Of Unify = Format.Thunk
--
--       unify :: forall m t2 t1. Creator Unify m
--             => Term t1 -> Term t2
--             -> m (Term (Layout.Layout
--                      '[ Model := (Layout.MergeList '[Unify])
--                       , Terms := (Layout.MergeList '[t1, t2])]))
--       unify t1 t2 = Term.newM $ \self -> pure Unify <*> fieldCons self t1
--                                                     <*> fieldCons self t2
--       {-# INLINE unify #-}
--
--       unify' :: forall m t2 t1 out.
--                 ( Creator Unify m
--                 , Layout.Relayout <unify output type> out
--                 ) -> Term t1 -> Term t2 -> m (Term out)
--       unify' t1 t2 = Layout.relayout <$> unify t1 t2
--       {-# INLINE unify' #-}
--   @
--
--   Moreover:
--   1. TODO: Every single field data type is converted to newtype by default.

define :: Name -> Q [Dec] -> Q [Dec]
define = defineChoice True

defineNoSmartCons :: Name -> Q [Dec] -> Q [Dec]
defineNoSmartCons = defineChoice False

defineChoice :: Bool -> Name -> Q [Dec] -> Q [Dec]
defineChoice needsSmartCons format declsQ = do
    decls <- declsQ
    concat <$> mapM (defineSingle needsSmartCons format) decls

defineSingle :: Bool -> Name -> Dec -> Q [Dec]
defineSingle needsSmartCons format termDecl = do
    (conName, param, con) <- case termDecl of
        TH.DataD _ conName [TH.PlainTV param] _ [con] _
          -> pure (conName, param, con)
        _ -> fail . unlines
           $ [ "Term constructor should be a data type parametrized with"
             , "a single type variable and a single constructor definition."
             ]
    let conNameStr      = convertTo @String conName
    case maybeNameStr con of
        (Just n) -> when_ (n /= conNameStr)
            $ fail "Term type should have the same name as its constructor."
    let typeNameStr   = mkTypeName conNameStr
        tagName       = convert conNameStr
        typeName      = convert typeNameStr

        mangleFields  = namedFields %~ fmap (_1 %~ mangleFieldName conNameStr)
        bangFields    = namedFields %~ fmap (_2 .~ unpackStrictAnn)
        rebindFields  = namedFields %~ fmap (_3 %~ expandField tagName)
        con'          = mangleFields
                      . bangFields
                      . rebindFields
                      $ con

        setTypeName   = maybeName    .~ Just typeName
        setDerivs     = derivClauses .~ [TH.DerivClause Nothing derivs]
        derivs        = cons' <$> [''Show, ''Eq]
        termDecl'     = (consList .~ [con'])
                      . setTypeName
                      . setDerivs
                      $ termDecl

        tagDecls      = Tag.familyInstance' ''Term.TermCons conNameStr
        isTermTagInst = TH.InstanceD Nothing []
                        (TH.AppT (cons' ''Discovery.IsTermTag) (cons' tagName))
                        []
        tagToConsInst = typeInstance ''Term.TagToCons [cons' tagName]
                        (cons' typeName)
        consToTagInst = typeInstance ''Term.ConsToTag [cons' typeName]
                        (cons' tagName)
        formatInst    = typeInstance ''Format.Of [cons' tagName] (cons' format)

        fieldTypes    = fmap (view _3) . view namedFields $ con

    lensInst      <- Lens.declareLenses (pure [termDecl'])
    storableInst  <- Storable.derive'   termDecl'
    storable1Inst <- Storable1.derive'  termDecl'
    smartCons     <- makeSmartCons tagName param fieldTypes

    pure $ tagDecls
        <> lensInst
        <> [ isTermTagInst
           , tagToConsInst
           , consToTagInst
           , formatInst
           ]
        <> storableInst
        <> storable1Inst
        <> if needsSmartCons then smartCons else []

    where maybeNameStr :: MayHaveName a => a -> (Maybe String)
          maybeNameStr = fmap TH.nameBase . view maybeName

expandField :: Name -> TH.Type -> TH.Type
expandField self field = app2 (cons' ''ExpandField) (cons' self) field
-- expandField self field = case field of
--     AppT (AppT (ConT n) t) a -> if n == ''LinkTo
--         then apps (cons' ''LinkTo__) [t, cons' self, a]
--         else field
--     _ -> field


-- === Helpers === --

unpackStrictAnn :: TH.Bang
unpackStrictAnn = TH.Bang TH.SourceUnpack TH.SourceStrict

mkTypeName :: (IsString a, Semigroup a) => a -> a
mkTypeName = ("Cons" <>)

mangleFieldName :: String -> Name -> Name
mangleFieldName sfx n = convert $ fixDuplicateRecordNamesGHCBug (convert n)
                               <> "_" <> sfx



--------------------------------
-- === Smart constructors === --
--------------------------------

makeSmartCons :: Name -> Name -> [TH.Type] -> Q [TH.Dec]
makeSmartCons tName param fieldTypes = do
    sigTypes <- inferSmartConsSigType tName param fieldTypes
    let sigType         = fst sigTypes
        genSigType      = snd sigTypes
        smartConsName   = lowerCase tName
        smartConsName'  = smartConsName <> "'"
        smartConsSig    = TH.SigD smartConsName  sigType
        smartConsGenSig = TH.SigD smartConsName' genSigType
        fieldNum        = length fieldTypes
    smartConsDef    <- makeSmartConsBody tName smartConsName fieldNum
    smartConsGenDef <- makeSmartConsGenBody smartConsName fieldNum
    -- pure $ smartConsSig : smartConsGenSig : (smartConsDef <> smartConsGenDef)
    pure $ smartConsSig : (smartConsDef)

type InputMap a = Map Name [a]

inferSmartConsSigType :: Name -> Name -> [TH.Type] -> Q (TH.Type, TH.Type)
inferSmartConsSigType name param fields = do
    tvs <- mapM (const $ TH.newName "t") fields
    mtv <- TH.newName "m"
    let ins   = zipWith (app2 (cons' ''FieldArg) . var :: Name -> TH.Type -> TH.Type) tvs fields
        outTp = inferSmartConsTypeOutput name $ zip tvs fields
        out   = app (var mtv) outTp
        inSig = arrows $ ins <> [out]
        ctx   = [app2 (cons' ''Term.Creator) (cons' name) (var mtv)]
        ptvs  = TH.PlainTV <$> (param : tvs <> [mtv])
        sig   = TH.ForallT ptvs ctx inSig

    -- genOutName <- newName "out"
    -- let genOut = app (var m) (var genOutName)
    --     genSig = arrows $ ins <> [genOut]
    --     genCtx = app2 (cons' ''Layout.Relayout) outTp (var genOutName) : ctx
    --     genTvs = TH.PlainTV genOutName : tvs

    --     genSigType = TH.ForallT genTvs genCtx genSig

    pure (sig, undefined)

arrows :: [TH.Type] -> TH.Type
arrows ts = foldl (flip arrow) a as where
    arrow a b = AppT (AppT TH.ArrowT a) b
    (a:as)    = reverse ts

-- inferSmartConsTypeInputs :: [TH.Type] -> Q ([TH.Type], InputMap Name)
-- inferSmartConsTypeInputs fields = State.runT (mapM inferSmartConsTypeInput fields)
--                               mempty

-- inferSmartConsTypeInput :: Name -> TH.Type -> TH.Type
-- inferSmartConsTypeInput name field = app2 (cons' ''FieldArg) (var name) field

    -- case field of
    -- AppT (AppT (ConT n) (ConT t)) a -> if n /= ''LinkTo
    --     then pure field
    --     else do
    --         State.modify_ @(InputMap Name) $ Map.insertWith (<>) t [var tvName]
    --         pure $ app (cons' ''Term) (var tvName)
    -- t -> pure t

inferSmartConsTypeOutput :: Name -> [(Name,TH.Type)] -> TH.Type
inferSmartConsTypeOutput tag ins = app (cons' ''Term) layout where
    layout = foldr ($) base (uncurry apply <$> ins)
    apply  = app3 (cons' ''AddToOutput) . var
    base   = app2 (cons' ''Layout.Singleton) (cons' ''Model) (cons' tag)
    -- empty  = app  (cons' ''Layout) $ fromList []

    -- type family AddToOutput tvar field layout


inferSmartConsTypeOutputField :: Name -> [TH.Type] -> TH.Type
inferSmartConsTypeOutputField k vs = field where
    tp    = app  (cons' ''Layout.MergeList) $ fromList vs
    field = app2 (cons' ''TypeMap.AssocP) (cons' k) tp

makeSmartConsBody :: Name -> Name -> Int -> Q [TH.Dec]
makeSmartConsBody tname fname varNum = do
    ins  <- newNames varNum
    self <- newName "self"
    let body      = app (var 'Term.newM) lam
        seg t a = app2 (var '(<*>)) t
                        (app2 (var 'fieldCons) (var self) a)
        lam       = TH.LamE [var self]
                  $ foldl seg (app (var 'pure) (cons' tname)) (var <$> ins)
        fn        = TH.FunD fname
                  $ [TH.Clause (TH.VarP <$> ins) (TH.NormalB body) []]
        inline    = TH.PragmaD (TH.InlineP fname TH.Inline TH.FunLike TH.AllPhases)

    pure [fn,inline]

makeSmartConsGenBody :: Name -> Int -> Q [TH.Dec]
makeSmartConsGenBody fname varNum = do
    ins <- newNames varNum
    let fname' = fname <> "'"
        body   = app2 (var 'fmap) (var 'Layout.relayout)
               $ apps (var fname) (var <$> ins)
        fn     = TH.FunD fname'
               $ [TH.Clause (TH.VarP <$> ins) (TH.NormalB body) []]
        inline = TH.PragmaD (TH.InlineP fname' TH.Inline TH.FunLike TH.AllPhases)
    pure [fn, inline]



--------------------------------
-- === UniTerm generation === --
--------------------------------

-- | IMPORTANT: Use 'makeUniTerm' in a place in code where all possible
--              terms are already declared.
--
--   The 'makeUniTerm' function discovers all already declared terms and
--   creates an unified datatype for processing them. Its purpose is also
--   to enumerate the terms, so we can use the ordering when serializing them.
--
--   The generated code looks like:
--
--       data UniTerm a
--           = UniTermTop     !(ConsTop     a)
--           | UniTermVar     !(ConsVar     a)
--           | UniTermMissing !(ConsMissing a)
--           ...
--           deriving (Show, Eq)
--       Storable.derive  ''UniTerm
--       Storable1.derive ''UniTerm
--
--       instance Term.IsUni ConsTop     where toUni = UniTermTop
--       instance Term.IsUni ConsVar     where toUni = UniTermVar
--       instance Term.IsUni ConsMissing where toUni = UniTermMissing
--
makeUniTerm :: Q [Dec]
makeUniTerm = do
    let unpackInst = \case
            TH.InstanceD _ _ (TH.AppT _ (TH.ConT n)) _ -> n
            _ -> error "impossible"
    termNames <- unpackInst <<$>> TH.reifyInstances ''Discovery.IsTermTag ["x"]
    let dataName     = "UniTerm"
        mkCons n     = TH.NormalC consName [(unpackStrictAnn, TH.AppT (TH.ConT childName) "a")] where
            consName  = dataName <> n
            childName = mkTypeName n
        derivs       = [TH.DerivClause Nothing $ cons' <$> [''Show, ''Eq]]
        dataDecl     = TH.DataD [] dataName ["a"] Nothing (mkCons <$> termNames)
                       derivs
        isUniInst n  = TH.InstanceD Nothing []
                       (TH.AppT (cons' ''Term.IsUni) (cons' $ mkTypeName n))
                       [TH.ValD "toUni" (TH.NormalB . cons' $ mkUniTermName n) []]
        isUniInsts   = isUniInst <$> termNames
    storableInst  <- Storable.derive'   dataDecl
    storable1Inst <- Storable1.derive'  dataDecl
    pure $ [ dataDecl
           ]
        <> storableInst
        <> storable1Inst
        <> isUniInsts

mkUniTermName :: (IsString a, Semigroup a) => a -> a
mkUniTermName = ("UniTerm" <>)
