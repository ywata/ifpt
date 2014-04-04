module GM where
import Language
import Parser
import Utils
import PrettyPrint

import Data.List (mapAccumL)

data AExpr = Num Int
           | Plus AExpr AExpr
           | Mult AExpr AExpr
           deriving(Show, Eq)

aInterpret :: AExpr -> Int
aInterpret (Num n) = n
aInterpret (Plus e1 e2) = aInterpret e1 + aInterpret e2
aInterpret (Mult e1 e2) = aInterpret e1 * aInterpret e2

data AInstruction = INum Int
                    | IPlus
                    | IMult
                    deriving(Show, Eq)


aEval :: ([AInstruction], [Int]) -> Int
aEval ([], [n]) = n
aEval (INum n:is, s) = aEval (is, n: s)
aEval (IPlus: is, n0:n1:s) = aEval(is, n1+n0:s)
aEval (IMult: is, n0:n1:s) = aEval (is, n1*n0:s)

aCompile::AExpr -> [AInstruction]
aCompile (Num n) = [INum n]
aCompile (Plus e1 e2) = aCompile e1 ++ aCompile e2 ++ [IPlus]
aCompile (Mult e1 e2) = aCompile e1 ++ aCompile e2 ++ [IMult]


runProg::String -> String
runProg = showResults . eval . compile . parse

type GmState = (GmCode, GmStack, GmHeap, GmGlobals, GmStats)
type GmCode = [Instruction]

getCode :: GmState -> GmCode
getCode (i, _, _, _, _) = i
putCode ::GmCode -> GmState -> GmState
putCode i' (_, stack, heap, globals, stats) = (i', stack, heap, globals, stats)

data Instruction = Unwind
                 | Pushglobal Name
                 | Pushint Int
                 | Push Int
                 | Mkap
                 | Slide Int
                 deriving(Show, Eq)

type GmStack = [Addr]

getStack :: GmState -> GmStack
getStack (_, stack, _, _, _) = stack
putStack::GmStack -> GmState -> GmState
putStack stack' (i, stack, heap, globals, stats) = (i, stack', heap, globals, stats)
type GmHeap = Heap Node
getHeap :: GmState -> GmHeap
getHeap (_, _, heap, _, _) = heap
putHeap:: GmHeap -> GmState -> GmState
putHeap heap' (i, stack, heap, globals, stats) = (i, stack, heap', globals, stats)

data Node = NNum Int
          | NAp Addr Addr
          | NGlobal Int GmCode
            deriving(Show, Eq)

type GmGlobals = ASSOC Name Addr

getGlobals :: GmState -> GmGlobals
getGlobals (_, _, _, globals, _) = globals

type GmStats = Int
statInitial::GmStats
statInitial = 0
statIncSteps::GmStats -> GmStats
statIncSteps s = s + 1
statGetSteps::GmStats -> Int
statGetSteps s = s
getStats :: GmState -> GmStats
getStats (_, _, _, _, stats) = stats
putStats::GmStats -> GmState -> GmState
putStats stats' (i, stack, heap, globals, stats) =
  (i, stack, heap, globals, stats')

eval :: GmState -> [GmState]
eval state = state: restStates
  where
    restStates | gmFinal state = []
               | otherwise = eval nextState
    nextState = doAdmin (step state)

doAdmin :: GmState -> GmState
doAdmin s = putStats (statIncSteps (getStats s)) s

gmFinal::GmState -> Bool
gmFinal s = case (getCode s) of
  [] -> True
  otherwise -> False

step::GmState -> GmState
step state = dispatch i (putCode is state)
  where
    (i:is) = getCode state

dispatch :: Instruction -> GmState -> GmState
dispatch (Pushglobal f) = pushglobal f
dispatch (Pushint n) = pushint n
dispatch Mkap = mkap
dispatch (Push n) = push n
dispatch (Slide n) = slide n
dispatch Unwind = unwind
pushglobal f state = putStack(a:getStack state) state
  where
    a = aLookup (getGlobals state) f (error $ "Undeclared global " ++ f)

pushint :: Int -> GmState -> GmState
pushint n state = putHeap heap' (putStack (a:getStack state) state)
  where
    (heap', a) = hAlloc (getHeap state) (NNum n)

mkap :: GmState -> GmState
mkap state = putHeap heap' (putStack (a:as') state)
  where
    (heap', a) = hAlloc (getHeap state) (NAp a1 a2)
    (a1:a2:as') = getStack state

push :: Int -> GmState -> GmState
push n state = putStack (a:as) state
  where
    as = getStack state
    a = getArg (hLookup (getHeap state) (as !! (n+1)))

getArg :: Node -> Addr
getArg (NAp a1 a2) = a2

slide :: Int -> GmState -> GmState
slide n state = putStack (a:drop n as) state
  where (a:as) = getStack state

unwind::GmState -> GmState
unwind state = newState (hLookup heap a)
  where
    (a:as) = getStack state
    heap = getHeap state
    newState (NNum n) = state
    newState (NAp a1 a2) = putCode [Unwind] (putStack (a1:a:as) state)
    newState (NGlobal n c)
      | length as < n = error "Unwinding with too few arguments"
      | otherwise = putCode c state


compile :: CoreProgram -> GmState
compile program = (initialCode, [], heap, globals, statInitial)
  where
    (heap, globals) = buildInitialHeap program
buildInitialHeap :: CoreProgram -> (GmHeap, GmGlobals)
buildInitialHeap program = mapAccumL allocateSc hInitial compiled
  where
    compiled = map compileSc program

type GmCompiledSC = (Name, Int, GmCode)
allocateSc :: GmHeap -> GmCompiledSC -> (GmHeap, (Name, Addr))
allocateSc heap (name, nargs, instns) = (heap', (name, addr))
  where
    (heap', addr) = hAlloc heap (NGlobal nargs instns)

initialCode :: GmCode
initialCode = [Pushglobal "main", Unwind]

compileSc :: (Name, [Name], CoreExpr) -> GmCompiledSC
compileSc (name, env, body) = (name, length env, compileR body (zip2 env [0..]))
compileR e env = compileC e env ++ [Slide (length env + 1), Unwind]

type GmCompiler = CoreExpr -> GmEnvironment -> GmCode
type GmEnvironment = ASSOC Name Int

compileC::GmCompiler
compileC (EVar v) env
  | elem v (aDomain env) = [Push n]
  | otherwise = [Pushglobal v]
  where
    n = aLookup env v (error "Can't happen")
compileC (ENum n) env = [Pushint n]
compileC (EAp e1 e2) env = compileC e2 env ++
                           compileC e1 (argOffset 1 env) ++ [Mkap]
argOffset :: Int -> GmEnvironment -> GmEnvironment
argOffset n env = [(v, n+m)|(v,m) <- env]

a = compileSc ("K", ["x", "y"], EVar "x")

compiledPrimitivies :: [GmCompiledSC]
compiledPrimitivies = []

showResults :: [GmState] -> [Char]
showResults states =
  iDisplay (iConcat [
               iStr "Supercombinator definitions", iNewline,
               iInterleave iNewline (map (showSC s) (getGlobals s)),
               iNewline, iNewline, iStr "State transitions", iNewline, iNewline,
               iLayn (map showState states), iNewline, iNewline,
               showStats (last states)])
  where
    (s:ss) = states

showSC :: GmState -> (Name, Addr) -> Iseq
showSC s (name, addr) =
  iConcat [ iStr "Code for ", iStr name, iNewline,
            showInstructions code, iNewline, iNewline]
  where
    (NGlobal arity code) = (hLookup (getHeap s) addr)
showInstructions :: GmCode -> Iseq
showInstructions is =
  iConcat [iStr "  Code:{",
           iIndent (iInterleave iNewline (map showInstruction is)),
           iStr "}", iNewline]
           
showInstruction:: Instruction -> Iseq
showInstruction Unwind = iStr "Unwind"
showInstruction (Pushglobal f) = (iStr "Pushglobal ") `iAppend` (iStr f)
showInstruction (Push n) = (iStr "Push ") `iAppend` (iNum n)
showInstruction (Pushint n) = (iStr "Pushint ") `iAppend` (iNum n)
showInstruction Mkap = iStr "Mkap"
showInstruction (Slide n) = (iStr "Slide ") `iAppend` (iNum n)

showState::GmState -> Iseq
showState s = iConcat [showStack s, iNewline,
                       showInstructions (getCode s), iNewline]
showStack :: GmState -> Iseq
showStack s =
  iConcat [iStr " Stack:[",
           iIndent (iInterleave iNewline
                    (map (showStackItem s) (reverse (getStack s)))),
           iStr "]"]
showStackItem :: GmState -> Addr -> Iseq
showStackItem s a =
  iConcat [iStr (showaddr a), iStr ": ",
           showNode s a (hLookup (getHeap s) a)]

showNode :: GmState -> Addr -> Node -> Iseq
showNode s a (NNum n) = iNum n
showNode s a (NGlobal n g) = iConcat [iStr "Global ", iStr v]
  where
    v = head [n|(n,b) <- getGlobals s, a == b]
showNode s a (NAp a1 a2) = iConcat [iStr "Ap ", iStr (showaddr a1),
                                    iStr " ", iStr (showaddr a2)]
showStats :: GmState -> Iseq
showStats s =
  iConcat [iStr "Steps taken = ", iNum (statGetSteps (getStats s))]

