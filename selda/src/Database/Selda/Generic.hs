{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TypeFamilies, TypeOperators, FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, ConstraintKinds #-}
{-# LANGUAGE GADTs, CPP, DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
-- | Generics utilities.
module Database.Selda.Generic
  ( Relational (..), Generic
  , tblCols, params, def, gNew, gRow
  , oneValueParam, oneValueTblCol, oneValueNew, oneValueRow
  , mkColName
  ) where
import Control.Monad.State
    ( MonadState(put, get), evalState, State )
import Control.Monad (liftM2)
import Data.Dynamic ( Typeable )
import Data.Text as Text (Text, pack)

import Data.Typeable ( Proxy(..), typeRep, typeRepTyCon )

import GHC.Generics
    ( Generic(from, Rep), Selector(selName), K1(K1), M1(M1), S )
import qualified GHC.Generics as G
    ( (:*:)(..), Selector, (:+:)(..) )
import qualified GHC.TypeLits as TL
import qualified Database.Selda.Column as C (Col)
import Control.Exception (Exception (..), try, throw)
import System.IO.Unsafe ( unsafePerformIO )
import Database.Selda.Types ( ColName, modColName, mkColName )
import Database.Selda.SqlType
    ( Lit, SqlType(sqlType, defaultValue, mkLit) )
import Database.Selda.SqlRow (SqlRow)
import Database.Selda.Table.Type
    ( ColAttr(Required, Optional), ColInfo(..) )
import Database.Selda.SQL (Param (..))
import Database.Selda.Exp (Exp (Col, Lit), UntypedCol (..))




-- | Any type which has a corresponding relation.
--   To make a @Relational@ instance for some type, simply derive 'Generic'.
--
--   Note that only types which have a single data constructor, and where all
--   fields are instances of 'SqlValue' can be used with this module.
--   Attempting to use functions in this module with any type which doesn't
--   obey those constraints will result in a very confusing type error.
class (SqlRow a) => Relational a where
  relParams :: a -> IO [Either Param Param]
  
  default relParams :: (Generic a, GRelation (Rep a)) => a -> IO [Either Param Param]
  relParams = gParams . from
  {-# INLINE relParams #-}
  
  relTblCols :: Proxy a
             -> (Int -> Maybe ColName -> ColName)
             -> State Int [ColInfo]
  
  default relTblCols :: (Generic a, GRelation (Rep a))
                     => Proxy a
                     -> (Int -> Maybe ColName -> ColName)
                     -> State Int [ColInfo]
  relTblCols _ = gTblCols (Proxy :: Proxy (Rep a)) Nothing
  {-# INLINE relTblCols #-}
  
  relNew :: Proxy a -> [UntypedCol sql]
  
  default relNew :: (Generic a, GRelation (Rep a)) => Proxy a -> [UntypedCol sql]
  relNew _ = gNew (Proxy :: Proxy (Rep a))
  {-# INLINE relNew #-}
  
  relRow :: a -> [UntypedCol sql]
  
  default relRow :: (Generic a, GRelation (Rep a)) => a -> [UntypedCol sql]
  relRow = gRow . from
  {-# INLINE relRow #-}

instance (SqlType a, SqlType b) => Relational (a,b)
instance (SqlType a, SqlType b, SqlType c) => Relational (a,b,c)
instance (SqlType a, SqlType b, SqlType c, SqlType d) => Relational (a,b,c,d)
instance (SqlType a, SqlType b, SqlType c, SqlType d, SqlType e) => Relational (a,b,c,d,e)
instance (SqlType a, SqlType b, SqlType c, SqlType d, SqlType e, SqlType f) => Relational (a,b,c,d,e,f)
instance (SqlType a, SqlType b, SqlType c, SqlType d, SqlType e, SqlType f, SqlType g) => Relational (a,b,c,d,e,f,g)

-- | Extract all insert parameters from a generic value.
params :: Relational a => a -> [Either Param Param]
params = unsafePerformIO . relParams

-- | Extract all column names from the given type.
--   If the type is not a record, the columns will be named @col_1@,
--   @col_2@, etc.
tblCols :: forall a. Relational a => Proxy a -> (Text -> Text) -> [ColInfo]
tblCols p fieldMod =
    evalState (relTblCols p rename) 0
  where
    rename n Nothing     = mkColName $ fieldMod ("col_" <> pack (show n))
    rename _ (Just name) = modColName name fieldMod

-- | Exception indicating the use of a default value.
--   If any values throwing this during evaluation of @param xs@ will be
--   replaced by their default value.
data DefaultValueException = DefaultValueException
  deriving Show
instance Exception DefaultValueException

-- | The default value for a column during insertion.
--   For an auto-incrementing primary key, the default value is the next key.
--
--   Using @def@ in any other context than insertion results in a runtime error.
def :: SqlType a => a
def = throw DefaultValueException

class GRelation f where
  -- | Generic worker for 'params'.
  gParams :: f a -> IO [Either Param Param]

  -- | Compute all columns needed to represent the given type.
  gTblCols :: Proxy f
           -> Maybe ColName
           -> (Int -> Maybe ColName -> ColName)
           -> State Int [ColInfo]

  -- | Create a new value with all default fields.
  gNew :: Proxy f -> [UntypedCol sql]

  -- | Create a new row from the given value.
  gRow :: f a -> [UntypedCol sql]

instance {-# OVERLAPPABLE #-} GRelation a => GRelation (M1 t c a) where
  gParams (M1 x) = gParams x
  gTblCols _ = gTblCols (Proxy :: Proxy a)
  gNew _ = gNew (Proxy :: Proxy a)
  gRow (M1 x) = gRow x

instance {-# OVERLAPPING #-} (G.Selector c, GRelation a) =>
         GRelation (M1 S c a) where
  gParams (M1 x) = gParams x
  gTblCols _ _ = gTblCols (Proxy :: Proxy a) name
    where
      name =
        case selName ((M1 undefined) :: M1 S c a b) of
          "" -> Nothing
          s  -> Just (mkColName $ pack s)
  gNew _ = gNew (Proxy :: Proxy a)
  gRow (M1 x) = gRow x

oneValueParam :: forall a. (SqlType a) => a -> IO (Either Param Param)
oneValueParam x = do
  res <- try $ return $! x
  return $ case res of
    Right x'                   -> Right $ Param (mkLit x')
    Left DefaultValueException -> Left $ Param (defaultValue :: Lit a)

oneValueTblCol :: (SqlType a)
               => Proxy a
               -> Maybe ColName
               -> (Int -> Maybe ColName -> ColName)
               -> State Int ColInfo
oneValueTblCol p name rename = do
    n <- get
    put (n+1)
    let name' = rename n name
    return $
      ColInfo
        { colName = name'
        , colType = sqlType p
        , colAttrs = optReq
        , colFKs = []
        , colExpr = Untyped (Col name')
        }
  where
      -- workaround for GHC 8.2 not resolving overlapping instances properly
      maybeTyCon = typeRepTyCon (typeRep (Proxy :: Proxy (Maybe ())))
      optReq
        | typeRepTyCon (typeRep p) == maybeTyCon = [Optional]
        | otherwise                              = [Required]

oneValueNew :: forall a sql. (SqlType a) => Proxy a -> UntypedCol sql
oneValueNew _ = Untyped (Lit (defaultValue :: Lit a))

oneValueRow :: (SqlType a) => a -> UntypedCol sql
oneValueRow x = Untyped (Lit (mkLit x))

instance (Typeable a, SqlType a) => GRelation (K1 i a) where
  gParams (K1 x) = (:[]) <$> oneValueParam x
  gTblCols _ name rename = (:[]) <$> oneValueTblCol (Proxy :: Proxy a) name rename
  gNew _ = [oneValueNew (Proxy :: Proxy a)]
  gRow (K1 x) = [oneValueRow x]

instance (GRelation a, GRelation b) => GRelation (a G.:*: b) where
  gParams (a G.:*: b) = liftM2 (++) (gParams a) (gParams b)
  gTblCols _ _ rename = do
      as <- gTblCols a Nothing rename
      bs <- gTblCols b Nothing rename
      return (as ++ bs)
    where
      a = Proxy :: Proxy a
      b = Proxy :: Proxy b
  gNew _ = gNew (Proxy :: Proxy a) ++ gNew (Proxy :: Proxy b)
  gRow (a G.:*: b) = gRow a ++ gRow b

instance
  (TL.TypeError
    ( 'TL.Text "Selda currently does not support creating tables from sum types."
      'TL.:$$:
      'TL.Text "Restrict your table type to a single data constructor."
    )) => GRelation (a G.:+: b) where
  gParams = error "unreachable"
  gTblCols = error "unreachable"
  gNew = error "unreachable"
  gRow = error "unreachable"

instance {-# OVERLAPS #-}
  (TL.TypeError
    ( 'TL.Text "Columns are now allowed to nest other columns."
      'TL.:$$:
      'TL.Text "Remove any fields of type 'Col s a' from your table type."
    )) => GRelation (K1 i (C.Col s a)) where
  gParams = error "unreachable"
  gTblCols = error "unreachable"
  gNew = error "unreachable"
  gRow = error "unreachable"
