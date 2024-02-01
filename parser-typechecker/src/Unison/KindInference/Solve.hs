module Unison.KindInference.Solve
  ( step,
    verify,
    initialState,
    defaultUnconstrainedVars,
    KindError (..),
    ConstraintConflict (..),
  )
where

import Control.Lens (Prism', prism', review, (%~))
import Control.Monad.Reader (asks)
import Control.Monad.Reader qualified as M
import Control.Monad.State.Strict qualified as M
import Control.Monad.Trans.Except
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Unison.Codebase.BuiltinAnnotation (BuiltinAnnotation)
import Unison.Debug (DebugFlag (KindInference), shouldDebug)
import Unison.KindInference.Constraint.Provenance (Provenance (..))
import Unison.KindInference.Constraint.Solved qualified as Solved
import Unison.KindInference.Constraint.StarProvenance (StarProvenance (..))
import Unison.KindInference.Constraint.Unsolved qualified as Unsolved
import Unison.KindInference.Error (ConstraintConflict (..), KindError (..), improveError)
import Unison.KindInference.Generate (builtinConstraints)
import Unison.KindInference.Generate.Monad (Gen (..), GeneratedConstraint)
import Unison.KindInference.Solve.Monad
  ( ConstraintMap,
    Descriptor (..),
    Env (..),
    Solve (..),
    SolveState (..),
    emptyState,
    run,
    runGen,
  )
import Unison.KindInference.UVar (UVar (..))
import Unison.PatternMatchCoverage.Pretty as P
import Unison.PatternMatchCoverage.UFMap qualified as U
import Unison.Prelude
import Unison.PrettyPrintEnv (PrettyPrintEnv)
import Unison.Syntax.TypePrinter qualified as TP
import Unison.Util.Pretty qualified as P
import Unison.Var (Var)

type UnsolvedConstraint v loc = Unsolved.Constraint (UVar v loc) v loc StarProvenance

_Generated :: forall v loc. Prism' (UnsolvedConstraint v loc) (GeneratedConstraint v loc)
_Generated = prism' (Unsolved.starProv %~ NotDefault) \case
  Unsolved.IsType s l -> case l of
    Default -> Nothing
    NotDefault l -> Just (Unsolved.IsType s l)
  Unsolved.IsAbility s l -> Just (Unsolved.IsAbility s l)
  Unsolved.IsArr s l a b -> Just (Unsolved.IsArr s l a b)
  Unsolved.Unify l a b -> Just (Unsolved.Unify l a b)

-- | Apply some generated constraints to a solve state, returning a
-- kind error if detected or a new solve state.
step ::
  (Var v, Ord loc, Show loc) =>
  Env ->
  SolveState v loc ->
  [GeneratedConstraint v loc] ->
  Either (NonEmpty (KindError v loc)) (SolveState v loc)
step e st cs =
  let action = do
        reduce cs >>= \case
          [] -> pure (Right ())
          e : es -> do
            -- We have an error, but do an occ check first to ensure
            -- we present the most sensible error.
            st <- M.get
            case verify st of
              Left e -> pure (Left e)
              Right _ -> do
                Left <$> traverse improveError (e :| es)
   in case unSolve action e st of
        (res, finalState) -> case res of
          Left e -> Left e
          Right () -> Right finalState

-- | Default any unconstrained vars to *
defaultUnconstrainedVars :: Var v => SolveState v loc -> SolveState v loc
defaultUnconstrainedVars st =
  let newConstraints = foldl' phi (constraints st) (newUnifVars st)
      phi b a = U.alter a handleNothing handleJust b
      handleNothing = error "impossible"
      handleJust _canonK ecSize d = case descriptorConstraint d of
        Nothing -> U.Canonical ecSize d {descriptorConstraint = Just $ Solved.IsType Default}
        Just _ -> U.Canonical ecSize d
   in st {constraints = newConstraints, newUnifVars = []}

prettyConstraintD' :: Show loc => Var v => PrettyPrintEnv -> UnsolvedConstraint v loc -> P.Pretty P.ColorText
prettyConstraintD' ppe =
  P.wrap . \case
    Unsolved.IsType v p -> prettyUVar ppe v <> " ~ Type" <> prettyProv p
    Unsolved.IsAbility v p -> prettyUVar ppe v <> " ~ Ability" <> prettyProv p
    Unsolved.IsArr v p a b -> prettyUVar ppe v <> " ~ " <> prettyUVar ppe a <> " -> " <> prettyUVar ppe b <> prettyProv p
    Unsolved.Unify p a b -> prettyUVar ppe a <> " ~ " <> prettyUVar ppe b <> prettyProv p
  where
    prettyProv x =
      "[" <> P.string (show x) <> "]"

prettyConstraints :: Show loc => Var v => PrettyPrintEnv -> [UnsolvedConstraint v loc] -> P.Pretty P.ColorText
prettyConstraints ppe = P.sep "\n" . map (prettyConstraintD' ppe)

prettyUVar :: Var v => PrettyPrintEnv -> UVar v loc -> P.Pretty P.ColorText
prettyUVar ppe (UVar s t) = TP.pretty ppe t <> " :: " <> P.prettyVar s

tracePretty :: P.Pretty P.ColorText -> a -> a
tracePretty p = trace (P.toAnsiUnbroken p)

data OccCheckState v loc = OccCheckState
  { visitingSet :: Set (UVar v loc),
    visitingStack :: [UVar v loc],
    solvedSet :: Set (UVar v loc),
    solvedConstraints :: ConstraintMap v loc,
    kindErrors :: [KindError v loc]
  }

markVisiting :: Var v => UVar v loc -> M.State (OccCheckState v loc) CycleCheck
markVisiting x = do
  OccCheckState {visitingSet, visitingStack} <- M.get
  case Set.member x visitingSet of
    True -> do
      OccCheckState {solvedConstraints} <- M.get
      let loc = case U.lookupCanon x solvedConstraints of
            Just (_, _, Descriptor {descriptorConstraint = Just (Solved.IsArr (Provenance _ loc) _ _)}, _) -> loc
            _ -> error "cycle without IsArr constraint"
      addError (CycleDetected loc x solvedConstraints)
      pure Cycle
    False -> do
      M.modify \st ->
        st
          { visitingSet = Set.insert x visitingSet,
            visitingStack = x : visitingStack
          }
      pure NoCycle

unmarkVisiting :: Var v => UVar v loc -> M.State (OccCheckState v loc) ()
unmarkVisiting x = M.modify \st ->
  st
    { visitingSet = Set.delete x (visitingSet st),
      visitingStack = tail (visitingStack st),
      solvedSet = Set.insert x (solvedSet st)
    }

addError :: KindError v loc -> M.State (OccCheckState v loc) ()
addError ke = M.modify \st -> st {kindErrors = ke : kindErrors st}

isSolved :: Var v => UVar v loc -> M.State (OccCheckState v loc) Bool
isSolved x = do
  OccCheckState {solvedSet} <- M.get
  pure $ Set.member x solvedSet

data CycleCheck
  = Cycle
  | NoCycle

-- | occurence check and report any errors
occCheck ::
  forall v loc.
  Var v =>
  ConstraintMap v loc ->
  Either (NonEmpty (KindError v loc)) (ConstraintMap v loc)
occCheck constraints0 =
  let go ::
        [(UVar v loc)] ->
        M.State (OccCheckState v loc) ()
      go = \case
        [] -> pure ()
        u : us -> do
          isSolved u >>= \case
            True -> go us
            False -> do
              markVisiting u >>= \case
                Cycle -> pure ()
                NoCycle -> do
                  st@OccCheckState {solvedConstraints} <- M.get
                  let handleNothing = error "impossible"
                      handleJust _canonK ecSize d = case descriptorConstraint d of
                        Nothing -> ([], U.Canonical ecSize d {descriptorConstraint = Just $ Solved.IsType Default})
                        Just v ->
                          let descendants = case v of
                                Solved.IsType _ -> []
                                Solved.IsAbility _ -> []
                                Solved.IsArr _ a b -> [a, b]
                           in (descendants, U.Canonical ecSize d)
                  let (descendants, solvedConstraints') = U.alterF u handleNothing handleJust solvedConstraints
                  M.put st {solvedConstraints = solvedConstraints'}
                  go descendants
              unmarkVisiting u
              go us

      OccCheckState {solvedConstraints, kindErrors} =
        M.execState
          (go (U.keys constraints0))
          OccCheckState
            { visitingSet = Set.empty,
              visitingStack = [],
              solvedSet = Set.empty,
              solvedConstraints = constraints0,
              kindErrors = []
            }
   in case kindErrors of
        [] -> Right solvedConstraints
        e : es -> Left (e :| es)

-- | loop through the constraints, eliminating constraints until we
-- have some set that cannot be reduced
reduce ::
  forall v loc.
  (Show loc, Var v, Ord loc) =>
  [GeneratedConstraint v loc] ->
  Solve v loc [KindError v loc]
reduce cs0 = dbg "reduce" cs0 (go False [])
  where
    go b acc = \case
      [] -> case b of
        True -> dbg "go" acc (go False [])
        False -> for acc \c ->
          dbgSingle "failed to add constraint" c addConstraint >>= \case
            Left x -> pure x
            Right () -> error "impossible"
      c : cs ->
        addConstraint c >>= \case
          Left _ -> go b (c : acc) cs
          Right () -> go True acc cs
    dbg ::
      forall a.
      P.Pretty P.ColorText ->
      [GeneratedConstraint v loc] ->
      ([GeneratedConstraint v loc] -> Solve v loc a) ->
      Solve v loc a
    dbg hdr cs f =
      case shouldDebug KindInference of
        True -> do
          ppe <- asks prettyPrintEnv
          tracePretty (P.hang (P.bold hdr) (prettyConstraints ppe (map (review _Generated) cs))) (f cs)
        False -> f cs

    dbgSingle ::
      forall a.
      P.Pretty P.ColorText ->
      GeneratedConstraint v loc ->
      (GeneratedConstraint v loc -> Solve v loc a) ->
      Solve v loc a
    dbgSingle hdr c f =
      case shouldDebug KindInference of
        True -> do
          ppe <- asks prettyPrintEnv
          tracePretty (P.hang (P.bold hdr) (prettyConstraintD' ppe (review _Generated c))) (f c)
        False -> f c

-- | Add a single constraint, returning an error if there is a
-- contradictory constraint
addConstraint ::
  forall v loc.
  Ord loc =>
  Var v =>
  GeneratedConstraint v loc ->
  Solve v loc (Either (KindError v loc) ())
addConstraint constraint = do
  initialState <- M.get

  -- Process implied constraints until they are all solved or an error
  -- is encountered
  let processPostAction ::
        Either (ConstraintConflict v loc) [UnsolvedConstraint v loc] ->
        Solve v loc (Either (KindError v loc) ())
      processPostAction = \case
        -- failure
        Left cc -> do
          -- roll back state changes
          M.put initialState
          pure (Left (ConstraintConflict constraint cc (constraints initialState)))
        -- success
        Right [] -> pure (Right ())
        -- undetermined
        Right (x : xs) -> do
          -- we could return a list of kind errors that are implied by
          -- this constraint, but for now we just return the first
          -- contradiction.
          processPostAction . fmap concat =<< runExceptT ((traverse (ExceptT . addConstraint') (x : xs)))
  processPostAction =<< addConstraint' (review _Generated constraint)

addConstraint' ::
  forall v loc.
  Ord loc =>
  Var v =>
  UnsolvedConstraint v loc ->
  Solve v loc (Either (ConstraintConflict v loc) [UnsolvedConstraint v loc])
addConstraint' = \case
  Unsolved.IsAbility s p0 -> do
    handleConstraint s (Solved.IsAbility p0) \case
      Solved.IsAbility _ -> Just (Solved.IsAbility p0, [])
      _ -> Nothing
  Unsolved.IsArr s p0 a b -> do
    handleConstraint s (Solved.IsArr p0 a b) \case
      Solved.IsArr _p1 c d ->
        let implied =
              [ Unsolved.Unify prov a c,
                Unsolved.Unify prov b d
              ]
            prov = p0
         in Just (Solved.IsArr prov a b, implied)
      _ -> Nothing
  Unsolved.IsType s p0 -> do
    handleConstraint s (Solved.IsType p0) \case
      Solved.IsType _ -> Just (Solved.IsType p0, [])
      _ -> Nothing
  Unsolved.Unify l a b -> Right <$> union l a b
  where
    handleConstraint ::
      UVar v loc ->
      Solved.Constraint (UVar v loc) v loc ->
      ( Solved.Constraint (UVar v loc) v loc ->
        Maybe (Solved.Constraint (UVar v loc) v loc, [UnsolvedConstraint v loc])
      ) ->
      Solve v loc (Either (ConstraintConflict v loc) [UnsolvedConstraint v loc])
    handleConstraint s solvedConstraint phi = do
      st@SolveState {constraints} <- M.get
      let (postAction, constraints') =
            U.alterF
              s
              (error "adding new uvar?")
              ( \_canon eqSize des@Descriptor {descriptorConstraint} ->
                  let newDescriptor = case descriptorConstraint of
                        Nothing -> (Right [], des {descriptorConstraint = Just solvedConstraint})
                        Just c1' -> case phi c1' of
                          Just (newConstraint, impliedConstraints) ->
                            (Right impliedConstraints, des {descriptorConstraint = Just newConstraint})
                          Nothing ->
                            let conflict =
                                  ConstraintConflict'
                                    { conflictedVar = s,
                                      impliedConstraint = solvedConstraint,
                                      conflictedConstraint = c1'
                                    }
                             in (Left conflict, des {descriptorConstraint = descriptorConstraint})
                   in U.Canonical eqSize <$> newDescriptor
              )
              constraints
      M.put st {constraints = constraints'}
      pure postAction

-- unify two uvars, returning implied constraints
union :: (Ord loc, Var v) => Provenance v loc -> UVar v loc -> UVar v loc -> Solve v loc [UnsolvedConstraint v loc]
union _unionLoc a b = do
  SolveState {constraints} <- M.get
  res <- U.union a b constraints noMerge \_canonK nonCanonV constraints' -> do
    st <- M.get
    M.put st {constraints = constraints'}
    let impliedConstraints = case descriptorConstraint nonCanonV of
          Nothing -> []
          Just c ->
            let cd = case c of
                  Solved.IsType loc -> Unsolved.IsType a case loc of
                    Default -> Default
                    NotDefault loc -> NotDefault loc
                  Solved.IsArr loc l r -> Unsolved.IsArr a loc l r
                  Solved.IsAbility loc -> Unsolved.IsAbility a loc
             in [cd]
    pure (Just impliedConstraints)

  case res of
    Nothing -> error "impossible"
    Just impliedConstraints -> pure impliedConstraints
  where
    noMerge m = do
      st <- M.get
      M.put st {constraints = m}
      pure []

-- | Do an occurence check and return an error or the resulting solve
-- state
verify ::
  Var v =>
  SolveState v loc ->
  Either (NonEmpty (KindError v loc)) (SolveState v loc)
verify st =
  let solveState = occCheck (constraints st)
   in case solveState of
        Left e -> Left e
        Right m -> Right st {constraints = m}

initializeState :: forall v loc. (BuiltinAnnotation loc, Ord loc, Show loc, Var v) => Solve v loc ()
initializeState = assertGen do
  builtinConstraints

-- | Generate and solve constraints, asserting no conflicts or
-- decomposition occurs
assertGen :: (Ord loc, Show loc, Var v) => Gen v loc [GeneratedConstraint v loc] -> Solve v loc ()
assertGen gen = do
  cs <- runGen gen
  env <- M.ask
  st <- M.get
  let comp = do
        st <- step env st cs
        verify st
  case comp of
    Left _ -> error "[assertGen]: constraint failure in among builtin constraints"
    Right st -> M.put st

initialState :: forall v loc. (BuiltinAnnotation loc, Show loc, Ord loc, Var v) => Env -> SolveState v loc
initialState env =
  let ((), finalState) = run env emptyState initializeState
   in finalState