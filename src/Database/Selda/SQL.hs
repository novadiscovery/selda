{-# LANGUAGE GADTs, OverloadedStrings #-}
-- | SQL AST and pretty-printing.
module Database.Selda.SQL where
import Database.Selda.Column
import Database.Selda.SqlType
import Database.Selda.Types (TableName)
import Data.Monoid

-- | AST for SQL queries.
data SQL = SQL
  { cols      :: [SomeCol]
  , source    :: Either TableName [SQL]
  , restricts :: [Exp Bool]
  , groups    :: [SomeCol]
  , ordering  :: [(Order, SomeCol)]
  , limits    :: Maybe (Int, Int)
  }

-- | The order in which to sort result rows.
data Order = Asc | Desc
  deriving (Show, Ord, Eq)

-- | A parameter to a prepared SQL statement.
data Param where
  Param :: Lit a -> Param

instance Show Param where
  show (Param l) = "Param " <> show l