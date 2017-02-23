{-# LANGUAGE PatternGuards #-}
module Cryptol.TypeCheck.SimpType where

import Control.Applicative((<|>))
import Cryptol.TypeCheck.Type hiding
  (tAdd,tSub,tMul,tDiv,tMod,tExp,tMin,tMax,tWidth,tLenFromThen,tLenFromThenTo)
import Cryptol.TypeCheck.TypePat
import Cryptol.TypeCheck.Solver.InfNat
import Control.Monad(msum,guard)
import Cryptol.TypeCheck.PP(pp)


tRebuild' :: Bool -> Type -> Type
tRebuild' withUser = go
  where
  go ty =
    case ty of
      TUser x xs t
        | withUser  -> TUser x xs (go t)
        | otherwise -> go t
      TVar _       -> ty
      TRec xs      -> TRec [ (x,go y) | (x,y) <- xs ]
      TCon tc ts ->
        case (tc, map go ts) of
          (TF f, ts') ->
            case (f,ts') of
              (TCAdd,[x,y]) -> tAdd x y
              (TCSub,[x,y]) -> tSub x y
              (TCMul,[x,y]) -> tMul x y
              (TCExp,[x,y]) -> tExp x y
              (TCDiv,[x,y]) -> tDiv x y
              (TCMod,[x,y]) -> tMod x y
              (TCMin,[x,y]) -> tMin x y
              (TCMax,[x,y]) -> tMax x y
              (TCWidth,[x]) -> tWidth x
              (TCLenFromThen,[x,y,z]) -> tLenFromThen x y z
              (TCLenFromThenTo,[x,y,z]) -> tLenFromThenTo x y z
              _ -> TCon tc ts
          (_,ts') -> TCon tc ts'

tRebuild :: Type -> Type
tRebuild = tRebuild' True

-- Normal: constants to the left
tAdd :: Type -> Type -> Type
tAdd x y
  | Just t <- tOp TCAdd (total (op2 nAdd)) [x,y] = t
  | tIsInf x            = tInf
  | tIsInf y            = tInf
  | Just n <- tIsNum x  = addK n y
  | Just n <- tIsNum y  = addK n x
  | Just (n,x1) <- isSumK x = addK n (tAdd x1 y)
  | Just (n,y1) <- isSumK y = addK n (tAdd x y1)
  | Just v <- matchMaybe (do (a,b) <- (|-|) y
                             guard (x == b)
                             return a) = v
  | Just v <- matchMaybe (do (a,b) <- (|-|) x
                             guard (b == y)
                             return a) = v

  | Just v <- matchMaybe (factor <|> same <|> swapVars) = v

  | otherwise           = tf2 TCAdd x y
  where
  isSumK t = case tNoUser t of
               TCon (TF TCAdd) [ l, r ] ->
                 do n <- tIsNum l
                    return (n, r)
               _ -> Nothing

  addK 0 t = t
  addK n t | Just (m,b) <- isSumK t = tf2 TCAdd (tNum (n + m)) b
           | Just v <- matchMaybe
                     $ do (a,b) <- (|-|) t
                          (do m <- aNat b
                              return $ case compare n m of
                                         GT -> tAdd (tNum (n-m)) a
                                         EQ -> a
                                         LT -> tSub a (tNum (m-n)))
                            <|>
                            (do m <- aNat a
                                return (tSub (tNum (m+n)) b))
                      = v
           | otherwise              = tf2 TCAdd (tNum n) t

  factor = do (a,b1)  <- aMul x
              (a',b2) <- aMul y
              guard (a == a')
              return (tMul a (tAdd b1 b2))

  same = do guard (x == y)
            return (tMul (tNum (2 :: Int)) x)

  swapVars = do a <- aTVar x
                b <- aTVar y
                guard (b < a)
                return (tf2 TCAdd y x)

tSub :: Type -> Type -> Type
tSub x y
  | Just t <- tOp TCSub (op2 nSub) [x,y] = t
  | tIsInf y  = tBadNumber $ TCErrorMessage "Subtraction of `inf`."
  | Just 0 <- yNum = x
  | Just k <- yNum
  , TCon (TF TCAdd) [a,b] <- tNoUser x
  , Just n <- tIsNum a = case compare k n of
                           EQ -> b
                           LT -> tf2 TCAdd (tNum (n - k)) b
                           GT -> tSub b (tNum (k - n))

  | Just v <- matchMaybe (do (a,b) <- anAdd x
                             (guard (a == y) >> return b)
                                <|> (guard (b == y) >> return a))
                       = v

  | Just v <- matchMaybe (do (a,b) <- (|-|) y
                             return (tSub (tAdd x b) a)) = v

  | otherwise = tf2 TCSub x y
  where
  yNum = tIsNum y



-- Normal: constants to the left
tMul :: Type -> Type -> Type
tMul x y
  | Just t <- tOp TCMul (total (op2 nMul)) [x,y] = t
  | Just n <- tIsNum x  = mulK n y
  | Just n <- tIsNum y  = mulK n x
  | Just v <- matchMaybe swapVars = v
  | otherwise           = tf2 TCMul x y
  where
  mulK 0 _ = tNum (0 :: Int)
  mulK 1 t = t
  mulK n t | TCon (TF TCMul) [a,b] <- t'
           , Just a' <- tIsNat' a = case a' of
                                     Inf   -> t
                                     Nat m -> tf2 TCMul (tNum (n * m)) b
           | TCon (TF TCDiv) [a,b] <- t'
           , Just b' <- tIsNum b
           -- XXX: similar for a = b * k?
           , n == b' = tSub a (tMod a b)


           | otherwise = tf2 TCMul (tNum n) t
    where t' = tNoUser t

  swapVars = do a <- aTVar x
                b <- aTVar y
                guard (b < a)
                return (tf2 TCMul y x)



tDiv :: Type -> Type -> Type
tDiv x y
  | Just t <- tOp TCDiv (op2 nDiv) [x,y] = t
  | tIsInf x = tBadNumber $ TCErrorMessage "Division of `inf`."
  | Just 0 <- tIsNum y = tBadNumber $ TCErrorMessage "Division by 0."
  | otherwise = tf2 TCDiv x y


tMod :: Type -> Type -> Type
tMod x y
  | Just t <- tOp TCMod (op2 nMod) [x,y] = t
  | tIsInf x = tBadNumber $ TCErrorMessage "Modulus of `inf`."
  | Just 0 <- tIsNum x = tBadNumber $ TCErrorMessage "Modulus by 0."
  | otherwise = tf2 TCMod x y

tExp :: Type -> Type -> Type
tExp x y
  | Just t <- tOp TCExp (total (op2 nExp)) [x,y] = t
  | Just 0 <- tIsNum y = tNum (1 :: Int)
  | TCon (TF TCExp) [a,b] <- tNoUser y = tExp x (tMul a b)
  | otherwise = tf2 TCExp x y


-- Normal: constants to the left
tMin :: Type -> Type -> Type
tMin x y
  | Just t <- tOp TCMin (total (op2 nMin)) [x,y] = t
  | Just n <- tIsNat' x = minK n y
  | Just n <- tIsNat' y = minK n x
  | Just n <- matchMaybe (minPlusK x y <|> minPlusK y x) = n
  | x == y              = x
  -- XXX: min (k + t) t -> t
  | otherwise           = tf2 TCMin x y
  where
  minPlusK a b = do (l,r) <- anAdd a
                    k     <- aNat l
                    guard (k >= 1 && b == r)
                    return b


  minK Inf t      = t
  minK (Nat 0) _  = tNum (0 :: Int)
  minK (Nat k) t
    | TCon (TF TCAdd) [a,b] <- t'
    , Just n <- tIsNum a   = if k <= n then tNum k
                                       else tAdd a (tMin (tNum (k - n)) b)

    | TCon (TF TCSub) [a,b] <- t'
    , Just n <- tIsNum a =
      if k >= n then t else tSub a (tMax (tNum (n - k)) b)

    | TCon (TF TCMin) [a,b] <- t'
    , Just n <- tIsNum a   = tf2 TCMin (tNum (min k n)) b

    | otherwise = tf2 TCMin (tNum k) t
    where t' = tNoUser t

-- Normal: constants to the left
tMax :: Type -> Type -> Type
tMax x y
  | Just t <- tOp TCMax (total (op2 nMax)) [x,y] = t
  | Just n <- tIsNat' x = maxK n y
  | Just n <- tIsNat' y = maxK n x
  | otherwise           = tf2 TCMax x y
  where
  maxK Inf _     = tInf
  maxK (Nat 0) t = t
  maxK (Nat k) t

    | TCon (TF TCAdd) [a,b] <- t'
    , Just n <- tIsNum a = if k <= n
                             then t
                             else tMax (tNum (k - n)) b

    | TCon (TF TCSub) [a,b] <- t'
    , Just n <- tIsNat' a =
      case n of
        Inf   -> t
        Nat m -> if k >= m then tNum k else tSub a (tMin (tNum (m - k)) b)

    | TCon (TF TCMax) [a,b] <- t'
    , Just n <- tIsNum a  = tf2 TCMax (tNum (max k n)) b

    | otherwise = tf2 TCMax (tNum k) t
    where t' = tNoUser t


tWidth :: Type -> Type
tWidth x
  | Just t <- tOp TCWidth (total (op1 nWidth)) [x] = t
  | otherwise = tf1 TCWidth x

tLenFromThen :: Type -> Type -> Type -> Type
tLenFromThen x y z
  | Just t <- tOp TCLenFromThen (op3 nLenFromThen) [x,y,z] = t
  -- XXX: rules?
  | otherwise = tf3 TCLenFromThen x y z

tLenFromThenTo :: Type -> Type -> Type -> Type
tLenFromThenTo x y z
  | Just t <- tOp TCLenFromThenTo (op3 nLenFromThenTo) [x,y,z] = t
  | otherwise = tf3 TCLenFromThenTo x y z

total :: ([Nat'] -> Nat') -> ([Nat'] -> Maybe Nat')
total f xs = Just (f xs)

op1 :: (a -> b) -> [a] -> b
op1 f ~[x] = f x

op2 :: (a -> a -> b) -> [a] -> b
op2 f ~[x,y] = f x y

op3 :: (a -> a -> a -> b) -> [a] -> b
op3 f ~[x,y,z] = f x y z

-- | Common checks: check for error, or simple full evaluation.
tOp :: TFun -> ([Nat'] -> Maybe Nat') -> [Type] -> Maybe Type
tOp tf f ts
  | Just e  <- msum (map tIsError ts) = Just (tBadNumber e)
  | Just xs <- mapM tIsNat' ts =
      Just $ case f xs of
               Nothing -> tBadNumber (err xs)
               Just n  -> tNat' n
  | otherwise = Nothing
  where
  err xs = TCErrorMessage $
              "Invalid applicatoin of " ++ show (pp tf) ++ " to " ++
                  unwords (map ppIN xs)

  ppIN Inf = "inf"
  ppIN (Nat x) = show x



