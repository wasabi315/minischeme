{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

module MiniScheme.Evaluator.Data
  ( Value',
    alloc,
    val,
    loc,
    undef,
    empty,
    true,
    false,
    ValueKind (..),
    Number,
    expectBool,
    expectNum,
    expectStr,
    expectSym,
    expectProc,
    Env,
    rootEnv,
    childEnv,
    lookup,
    bind,
    set,
    Symbol,
    SymTable,
    newSymTable,
    strToSym,
    symToStr,
    EvalError (..),
  )
where

import Control.Exception.Safe
import Control.Monad
import Control.Monad.IO.Class
import Data.HashTable.IO (BasicHashTable)
import Data.HashTable.IO qualified as HT
import Data.IORef
import Data.Maybe
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.IO.Unsafe
import MiniScheme.AST qualified as AST
import System.Mem.StableName
import Prelude hiding (lookup)

data Value' m = Value' (ValueKind m) (StableName (ValueKind m))

instance Show (Value' m) where
  show (Value' v _) = show v

val :: Value' m -> ValueKind m
val (Value' v _) = v

loc :: Value' m -> StableName (ValueKind m)
loc (Value' _ l) = l

alloc :: MonadIO m => ValueKind n -> m (Value' n)
alloc v = Value' v <$!> liftIO (makeStableName v)

undef, empty, true, false :: Value' m
undef = unsafePerformIO (alloc Undef)
empty = unsafePerformIO (alloc Empty)
true = unsafePerformIO (alloc (Bool True))
false = unsafePerformIO (alloc (Bool False))
{-# NOINLINE undef #-}
{-# NOINLINE empty #-}
{-# NOINLINE true #-}
{-# NOINLINE false #-}

data ValueKind m
  = Undef
  | Empty
  | Bool Bool
  | Num Number
  | Str Text
  | Sym Symbol
  | Proc (Env m) (Env m -> [Value' m] -> m (Value' m))

type Number = AST.Number

instance Show (ValueKind m) where
  show Undef = "#<undef>"
  show Empty = "()"
  show (Num n) = show n
  show (Bool b) = if b then "#t" else "#f"
  show (Str s) = show s
  show (Sym s) = show s
  show (Proc _ _) = "<procedure>"

expectNum :: MonadThrow m => Value' m -> m Integer
expectNum v = case val v of
  Num n -> pure n
  Undef -> throw (EvalError "undefined value evaluated")
  _ -> throw (EvalError "expect number")

expectBool :: MonadThrow m => Value' m -> m Bool
expectBool v = case val v of
  Bool b -> pure b
  Undef -> throw (EvalError "undefined value evaluated")
  _ -> throw (EvalError "expect boolean")

expectStr :: MonadThrow m => Value' m -> m Text
expectStr v = case val v of
  Str s -> pure s
  Undef -> throw (EvalError "undefined value evaluated")
  _ -> throw (EvalError "expect boolean")

expectSym :: MonadThrow m => Value' m -> m Symbol
expectSym v = case val v of
  Sym s -> pure s
  Undef -> throw (EvalError "undefined value evaluated")
  _ -> throw (EvalError "expect boolean")

expectProc ::
  MonadThrow m =>
  Value' m ->
  m (Env m, Env m -> [Value' m] -> m (Value' m))
expectProc v = case val v of
  Proc e f -> pure (e, f)
  Undef -> throw (EvalError "undefined value evaluated")
  _ -> throw (EvalError "expect boolean")

data Env m = Env
  { binds :: BasicHashTable AST.Id (IORef (Value' m)),
    parent :: Maybe (Env m)
  }

rootEnv :: MonadIO m => m (Env n)
rootEnv = flip Env Nothing <$!> liftIO HT.new

childEnv :: MonadIO m => Env n -> m (Env n)
childEnv parent = flip Env (Just parent) <$!> liftIO HT.new

lookup :: (MonadIO m, MonadThrow m) => Env n -> AST.Id -> m (IORef (Value' n))
lookup env i = lookup' env
  where
    lookup' Env {..} = do
      liftIO (HT.lookup binds i) >>= \case
        Just v -> pure v
        Nothing -> case parent of
          Just env' -> lookup' env'
          Nothing -> throw (EvalError $ "Unbound identifier: " <> i)

bind :: (MonadIO m, MonadThrow m) => Env n -> AST.Id -> Value' n -> m ()
bind Env {..} i v = do
  declared <- liftIO $ HT.mutateIO binds i \case
    Just v' -> pure (Just v', True)
    Nothing -> (,False) . Just <$> newIORef v
  when declared do
    throw (EvalError "identifier already declared")

set :: (MonadIO m, MonadThrow m) => Env n -> AST.Id -> Value' n -> m ()
set e i v = do
  ref <- lookup e i
  liftIO $ modifyIORef' ref (const v)

newtype Symbol = Symbol Text

instance Show Symbol where
  show (Symbol s) = Text.unpack s

newtype SymTable m = SymTable (BasicHashTable Text (Value' m))

newSymTable :: MonadIO m => m (SymTable n)
newSymTable = SymTable <$> liftIO HT.new

symToStr :: Symbol -> Text
symToStr (Symbol name) = name

strToSym :: MonadIO m => SymTable m -> Text -> m (Value' m)
strToSym (SymTable tbl) t = liftIO do
  HT.mutateIO tbl t \case
    Nothing -> do
      s <- alloc (Sym (Symbol t))
      pure (Just s, s)
    Just s -> pure (Just s, s)

newtype EvalError = EvalError Text

instance Show EvalError where
  show (EvalError reason) = Text.unpack reason

instance Exception EvalError
