{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Eval (
   evalText
  , evalFile
  , runParseTest
) where

import Parser
import Text.Parsec
import LispVal
import Prim

import Data.Text as T
import Data.Map as Map
import Data.Monoid
import System.Directory
import System.IO
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Resource

basicEnv :: Map.Map T.Text LispVal
basicEnv = Map.fromList $ primEnv
          <> [("read" , Fun $ IFunc $ unop readFn)]

readFn :: LispVal -> Eval LispVal
readFn x = do
  val <- eval x
  case val of
    (String txt) -> textToEvalForm txt
    _            -> throwError $ TypeMismatch "read expects string, instead got: " val


runASTinEnv :: EnvCtx -> Eval b -> ExceptT LispError IO b
runASTinEnv code action = do
    res <- liftIO $  runResourceT $ runExceptT $ runReaderT (unEval action) code
    ExceptT $ return res

evalText :: T.Text -> IO () --REPL
evalText textExpr = do
  out <- runExceptT $ runASTinEnv basicEnv $ textToEvalForm textExpr
  either print print out

textToEvalForm :: T.Text -> Eval LispVal
textToEvalForm input = either (throwError . PError . show  )  eval $ readExpr input

evalFile :: T.Text -> IO () --program file
evalFile fileExpr = do
  out <- runExceptT $ runASTinEnv basicEnv $ fileToEvalForm fileExpr
  either print print out

fileToEvalForm :: T.Text -> Eval LispVal
fileToEvalForm input = either (throwError . PError . show )  evalBody $ readExprFile input

runParseTest :: T.Text -> T.Text -- for view AST
runParseTest input = either (T.pack . show) (T.pack . show) $ readExpr input

getVar :: LispVal ->  Eval LispVal
getVar (Atom atom) = do
  env <- ask
  case Map.lookup atom env of
      Just x  -> return x
      Nothing -> throwError $ UnboundVar atom
getVar n = throwError $ TypeMismatch  "failure to get variable: " n

ensureAtom :: LispVal -> Eval LispVal
ensureAtom n@(Atom _) = return  n
ensureAtom n = throwError $ TypeMismatch "expected an atomic value" n

extractVar :: LispVal -> T.Text
extractVar (Atom atom) = atom

getEven :: [t] -> [t]
getEven [] = []
getEven (x:xs) = x : getOdd xs

getOdd :: [t] -> [t]
getOdd [] = []
getOdd (x:xs) = getEven xs 

applyLambda :: LispVal -> [LispVal] -> [LispVal] -> Eval LispVal
applyLambda expr params args = do 
  env <- ask
  argEval <- mapM eval args
  local (const (Map.fromList (Prelude.zipWith (\a b -> (extractVar a,b)) params argEval) <> env)) $ eval expr

eval :: LispVal -> Eval LispVal
eval (Number i) = return $ Number i
eval (String s) = return $ String s
eval (Bool b)   = return $ Bool b
eval (List [])  = return Nil
eval Nil        = return Nil
eval n@(Atom _) = getVar n

eval (List [Atom "write", rest])      = return . String . T.pack $ show rest
eval (List ((:) (Atom "write") rest)) = return . String . T.pack . show $ List rest

eval (List [Atom "quote", val]) = return val

eval (List [Atom "if", pred, ant, cons]) = do 
  ifRes <- eval pred
  case ifRes of
      (Bool True)  -> eval ant
      (Bool False) -> eval cons
      _            -> throwError $ BadSpecialForm "if's first arg must eval into a boolean"
eval args@(List ( (:) (Atom "if") _))  = throwError $ BadSpecialForm "(if <bool> <s-expr> <s-expr>)"

eval (List [Atom "begin", rest]) = evalBody rest
eval (List ((:) (Atom "begin") rest )) = evalBody $ List rest

eval (List [Atom "define", varExpr, expr]) = do --top-level define
  varAtom <- ensureAtom varExpr
  evalVal <- eval expr
  env     <- ask
  local (const $ Map.insert (extractVar varAtom) evalVal env) $ return varExpr

eval (List [Atom "let", List pairs, expr]) = do 
  env   <- ask
  atoms <- mapM ensureAtom $ getEven pairs
  vals  <- mapM eval       $ getOdd  pairs
  local (const (Map.fromList (Prelude.zipWith (\a b -> (extractVar a, b)) atoms vals) <> env))  $ evalBody expr
eval (List (Atom "let":_) ) = throwError $ BadSpecialForm "lambda funciton expects list of parameters and S-Expression body\n(let <pairs> <s-expr>)" 

eval (List [Atom "lambda", List params, expr]) = do 
  envLocal <- ask
  return  $ Lambda (IFunc $ applyLambda expr params) envLocal
eval (List (Atom "lambda":_) ) = throwError $ BadSpecialForm "lambda funciton expects list of parameters and S-Expression body\n(lambda <params> <s-expr>)" 

eval (List ((:) x xs)) = do 
  funVar <- eval x
  xVal   <- mapM eval  xs
  case funVar of
      (Fun (IFunc internalFn)) -> internalFn xVal
      (Lambda (IFunc internalfn) boundenv) -> local (const boundenv) $ internalfn xVal
      _                -> throwError $ NotFunction funVar 

eval x = throwError $ Default  x --fall thru

evalBody :: LispVal -> Eval LispVal
evalBody (List [List ((:) (Atom "define") [Atom var, defExpr]), rest]) = do 
  evalVal <- eval defExpr
  env     <- ask
  local (const $ Map.insert var evalVal env) $ eval rest

evalBody (List ((:) (List ((:) (Atom "define") [Atom var, defExpr])) rest)) = do 
  evalVal <- eval defExpr
  env     <- ask
  local (const $ Map.insert var evalVal env) $ evalBody $ List rest
evalBody x = eval x

