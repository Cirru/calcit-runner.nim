
import os
import sets
import strutils
# import unicode
import tables
import options
import strformat
import algorithm
import sequtils

import ternary_tree

import ../types
import ../util/errors
import ../util/str_util

const cLine = "\n"
const cCurlyL = "{"
const cCurlyR = "}"
const cDbQuote = "\""

# TODO dirty states controlling js backend
var jsMode* = false
var jsEmitPath* = "js-out"
var firstCompilation = true # track if it's the first compilation

# TODO mutable way of collect things
type ImplicitImportItem = tuple[ns: string, justNs: bool]
var implicitImports: Table[string, ImplicitImportItem]

proc toJsImportName(ns: string): string =
  ("./" & ns).escape() # currently use `import "./ns.name"`

proc toJsFileName(ns: string): string =
  ns & ".js"

proc hasNsPart(x: string): bool =
  let trySlashPos = x.find('/')
  return trySlashPos >= 1 and trySlashPos < x.len - 1

# handle mutual recursion
proc escapeNs(name: string): string

proc escapeVar(name: string): string =
  if name.hasNsPart():
    let pieces = name.split("/")
    if pieces.len != 2:
      raiseEvalError("Expected format of ns/def", CirruData(kind: crDataString, stringVal: name))
    let nsPart = pieces[0]
    let defPart = pieces[1]
    if nsPart == "js":
      return defPart
    else:
      return nsPart.escapeNs() & "." & defPart.escapeVar()

  result = name
  .replace("-", "_DASH_")
  .replace("?", "_QUES_")
  .replace("+", "_ADD_")
  # .replace(">", "_SHR_")
  .replace("*", "_STAR_")
  .replace("&", "_AND_")
  .replace("{}", "_MAP_")
  .replace("[]", "_LIST_")
  .replace("{", "_CURL_")
  .replace("}", "_CURR_")
  .replace("'", "_SQUO_")
  .replace("[", "_SQRL_")
  .replace("]", "_SQRR_")
  .replace("!", "_BANG_")
  .replace("%", "_PCT_")
  .replace("/", "_SLSH_")
  .replace("=", "_EQ_")
  .replace(">", "_GT_")
  .replace("<", "_LT_")
  .replace(";", "_SCOL_")
  .replace("#", "_SHA_")
  .replace("\\", "_BSL_")
  .replace(".", "_DOT_")
  if result == "if": result = "_IF_"
  if result == "do": result = "_DO_"
  if result == "else": result = "_ELSE_"
  if result == "let": result = "_LET_"
  if result == "case": result = "_CASE_"

# use `$` to tell namespace from normal variables, thus able to use same token like clj
proc escapeNs(name: string): string =
  "$" & name.escapeVar()

# handle recursion
proc genJsFunc(name: string, args: TernaryTreeList[CirruData], body: seq[CirruData], ns: string, exported: bool, outerDefs: HashSet[string]): string
proc genArgsCode(body: TernaryTreeList[CirruData], ns: string, localDefs: HashSet[string]): string

let builtInJsProc = toHashSet([
  "aget", "aset",
  "extract-cirru-edn",
  "to-cirru-edn",
  "to-js-data",
  "to-calcit-data",
])

# code generated from calcit.core.cirru may not be faster enough,
# possible way to use code from calcit.procs.ts
let preferredJsProc = toHashSet([
  "number?", "keyword?",
  "map?", "nil?",
  "list?", "set?",
  "string?", "fn?",
  "bool?", "atom?",
])

proc toJsCode(xs: CirruData, ns: string, localDefs: HashSet[string]): string =
  let varPrefix = if ns == "calcit.core": "" else: "$calcit."
  case xs.kind
  of crDataSymbol:
    if xs.symbolVal.hasNsPart():
      let nsPart = xs.symbolVal.split("/")[0]
      # TODO ditry code
      if nsPart != "js":
        if implicitImports.contains(nsPart):
          let prev = implicitImports[nsPart]
          if prev.justNs.not or prev.ns != nsPart:
            echo implicitImports, " ", xs
            raiseEvalError("Conflicted implicit ns import", xs)
        else:
          implicitImports[nsPart] = (ns: nsPart, justNs: true)
      return xs.symbolVal.escapeVar()
    elif xs.dynamic:
      return "new " & varPrefix & "CrDataSymbol(" & xs.symbolVal.escape() & ")"
    elif builtInJsProc.contains(xs.symbolVal):
      return varPrefix & xs.symbolVal.escapeVar()
    elif localDefs.contains(xs.symbolVal):
      return xs.symbolVal.escapeVar()
    elif xs.ns == coreNs:
      # local variales inside calcit.core also uses this ns
      return varPrefix & xs.symbolVal.escapeVar()
    elif xs.ns == "":
      raiseEvalError("Unpexpected ns at symbol", xs)
    elif xs.ns != ns: # probably via macro
      # TODO ditry code
      if implicitImports.contains(xs.symbolVal):
        let prev = implicitImports[xs.symbolVal]
        if prev.ns != xs.ns:
          echo implicitImports, " ", xs
          raiseEvalError("Conflicted implicit imports, probably via macro", xs)
      else:
        implicitImports[xs.symbolVal] = (ns: xs.ns, justNs: false)
      return xs.symbolVal.escapeVar()
    elif xs.resolved.isSome():
      # TODO ditry code
      let resolved = xs.resolved.get()
      if implicitImports.contains(xs.symbolVal):
        let prev = implicitImports[xs.symbolVal]
        if prev.ns != resolved.ns:
          echo implicitImports, " ", xs
          raiseEvalError("Conflicted implicit imports", xs)
      else:
        implicitImports[xs.symbolVal] = (ns: resolved.ns, justNs: false)
      return xs.symbolVal.escapeVar()
    elif xs.ns == ns:
      return xs.symbolVal.escapeVar()
    else:
      echo "[WARNING] Unpexpected case of code gen for ", xs, " in ", ns
      return varPrefix & xs.symbolVal.escapeVar()
  of crDataString:
    return xs.stringVal.escapeCirruStr()
  of crDataBool:
    return $xs.boolVal
  of crDataNumber:
    return $xs.numberVal
  of crDataTernary:
    return "initCrTernary(" & ($xs.ternaryVal).escape() & ")"
  of crDataNil:
    return "null"
  of crDataKeyword:
    return varPrefix & "kwd(" & xs.keywordVal.escape() & ")"
  of crDataList:
    if xs.listVal.len == 0:
      echo "[WARNING] Unpexpected empty list"
      return "()"
    let head = xs.listVal[0]
    let body = xs.listVal.rest()
    if head.kind == crDataSymbol:
      case head.symbolVal
      of "if":
        if body.len < 2:
          raiseEvalError("need branches for if", xs)
        let falseBranch = if body.len >= 3: body[2].toJsCode(ns, localDefs) else: "null"
        return "(" & body[0].toJsCode(ns, localDefs) & "?" & body[1].toJsCode(ns, localDefs) & ":" & falseBranch & ")"
      of "&let":
        result = result & "(()=>{"
        if body.len <= 1:
          raiseEvalError("Unpexpected empty content in let", xs)
        let pair = body.first()
        let content = body.rest()
        if pair.kind != crDataList:
          raiseEvalError("Expected pair a list of length 2", pair)
        if pair.listVal.len != 2:
          raiseEvalError("Expected pair of length 2", pair)
        let defName = pair.listVal[0]
        if defName.kind != crDataSymbol:
          raiseEvalError("Expected symbol behind let", pair)
        # TODO `let` inside expressions makes syntax error
        result = result & fmt"{cLine}let {defName.symbolVal.escapeVar} = {pair.listVal[1].toJsCode(ns, localDefs)};{cLine}"
        # defined new local variable
        var scopedDefs = localDefs
        scopedDefs.incl(defName.symbolVal)
        for idx, x in content:
          if idx == content.len - 1:
            result = result & "return " & x.toJsCode(ns, scopedDefs) & ";\n"
          else:
            result = result & x.toJsCode(ns, scopedDefs) & ";\n"
        return result & "})()"
      of ";":
        return "(/* " & $CirruData(kind: crDataList, listVal: body) & " */ null)"
      of "do":
        result = "(()=>{" & cLine
        for idx, x in body:
          if idx > 0:
            result = result & ";\n"
          if idx == body.len - 1:
            result = result & "return " & x.toJsCode(ns, localDefs)
          else:
            result = result & x.toJsCode(ns, localDefs)
        result = result & cLine & "})()"
        return result

      of "quote":
        if body.len < 1:
          raiseEvalError("Unpexpected empty body", xs)
        return ($body[0]).escapeCirruStr()
      of "defatom":
        if body.len != 2:
          raiseEvalError("defatom expects 2 nodes", xs)
        let atomName = body[0]
        let atomExpr = body[1]
        if atomName.kind != crDataSymbol:
          raiseEvalError("expects atomName in symbol", xs)
        let name = atomName.symbolVal.escapeVar()
        let atomPath = (ns & "/" & atomName.symbolVal).escape()
        return fmt"{cLine}({varPrefix}peekDefatom({atomPath}) ?? {varPrefix}defatom({atomPath}, {atomExpr.toJsCode(ns, localDefs)})){cLine}"

      of "defn":
        if body.len < 3:
          raiseEvalError("Expected name, args, code for gennerating func, too short", xs)
        let funcName = body[0]
        let funcArgs = body[1]
        let funcBody = body.rest().rest()
        if funcName.kind != crDataSymbol:
          raiseEvalError("Expected function name in a symbol", xs)
        if funcArgs.kind != crDataList:
          raiseEvalError("Expected function args in a list", xs)
        return genJsFunc(funcName.symbolVal, funcArgs.listVal, funcBody.toSeq(), ns, false, localDefs)

      of "defmacro":
        return "/* Unpexpected macro " & $xs & " */"
      of "quote-replace":
        return "/* Unpexpected quote-replace " & $xs & " */"
      of "raise":
        # not core syntax, but treat as macro for better debugging experience
        if body.len != 1:
          raiseEvalError("expected a single argument", body.toSeq())
        let message: string = $body[0]
        return fmt"(()=> {cCurlyL} throw new Error({message.escape}) {cCurlyR})() "
      of "exists?":
        if body.len != 1: raiseEvalError("expected 1 argument", xs)
        let item = body[0]
        if item.kind != crDataSymbol: raiseEvalError("expected a symbol", xs)
        # not core syntax, but treat as macro for better debugging experience
        return fmt"(typeof {item.symbolVal.escapeVar} !== 'undefined')"

      else:
        let token = head.symbolVal
        if token.len > 2 and token[0..1] == ".-" and token[2..^1].matchesJsVar():
          let name = token[2..^1]
          if xs.listVal.len != 2:
            raiseEvalError("property accessor takes only 1 argument", xs)
          let obj = xs.listVal[1]
          return obj.toJsCode(ns, localDefs) & "." & name
        elif token.len > 1 and token[0] == '.' and token[1..^1].matchesJsVar():
          let name = token[1..^1]
          if xs.listVal.len < 2:
            raiseEvalError("property accessor takes at least 1 argument", xs)
          let obj = xs.listVal[1]
          let args = xs.listVal.slice(2, xs.listVal.len)
          let argsCode = genArgsCode(args, ns, localDefs)
          return obj.toJsCode(ns, localDefs) & "." & name & "(" & argsCode & ")"
        else:
          discard
    var argsCode = genArgsCode(body, ns, localDefs)
    return head.toJsCode(ns, localDefs) & "(" & argsCode & ")"
  else:
    raiseEvalError("[WARNING] unknown kind to gen js code: " & $xs.kind, xs)

proc genArgsCode(body: TernaryTreeList[CirruData], ns: string, localDefs: HashSet[string]): string =
  let varPrefix = if ns == "calcit.core": "" else: "$calcit."
  var spreading = false
  for x in body:
    if x.kind == crDataSymbol and x.symbolVal == "&":
      spreading = true
    else:
      if result != "":
        result = result & ", "
      if spreading:
        result = result & fmt"...{varPrefix}listToArray(" & x.toJsCode(ns, localDefs) & ")"
      else:
        result = result & x.toJsCode(ns, localDefs)

proc toJsCode(xs: seq[CirruData], ns: string, localDefs: HashSet[string]): string =
  for idx, x in xs:
    # result = result & "// " & $x & "\n"
    if idx == xs.len - 1:
      result = result & "return " & x.toJsCode(ns, localDefs) & ";\n"
    else:
      result = result & x.toJsCode(ns, localDefs) & ";\n"

proc usesRecur(xs: CirruData): bool =
  case xs.kind
  of crDataSymbol:
    if xs.symbolVal == "recur":
      return true
    return false
  of crDataList:
    for x in xs.listVal:
      if x.usesRecur():
        return true
    return false
  else:
    return false

proc genJsFunc(name: string, args: TernaryTreeList[CirruData], body: seq[CirruData], ns: string, exported: bool, outerDefs: HashSet[string]): string =
  let varPrefix = if ns == "calcit.core": "" else: "$calcit."
  var localDefs = outerDefs
  var spreadingCode = "" # js list and calcit-js list are different, need to convert
  var argsCode = ""
  var spreading = false
  for x in args:
    if x.kind != crDataSymbol:
      raiseEvalError("Expected symbol for arg", x)
    if spreading:
      if argsCode != "":
        argsCode = argsCode & ", "
      localDefs.incl(x.symbolVal)
      let argName = x.symbolVal.escapeVar()
      argsCode = argsCode & "..." & argName
      # js list and calcit-js are different in spreading
      spreadingCode = spreadingCode & fmt"{cLine}{argName} = {varPrefix}arrayToList({argName});"
      spreading = false
    else:
      if x.symbolVal == "&":
        spreading = true
        continue
      if argsCode != "":
        argsCode = argsCode & ", "
      localDefs.incl(x.symbolVal)
      argsCode = argsCode & x.symbolVal.escapeVar

  var fnDefinition = fmt"function {name.escapeVar}({argsCode}) {cCurlyL}{spreadingCode}{cLine}{body.toJsCode(ns, localDefs)}{cCurlyR}"
  if body.len > 0 and body[^1].usesRecur():
    let varPrefix = if ns == "calcit.core": "" else: "$calcit."
    let exportMark = if exported: fmt"export let {name.escapeVar} = " else: ""
    return fmt"{exportMark}{varPrefix}wrapTailCall({fnDefinition}){cLine}"
  else:
    let exportMark = if exported: "export " else: ""
    return fmt"{exportMark}{fnDefinition}{cLine}"

proc containsSymbol(xs: CirruData, y: string): bool =
  case xs.kind
  of crDataSymbol:
    xs.symbolVal == y
  of crDataThunk:
    xs.thunkCode[].containsSymbol(y)
  of crDataFn:
    for x in xs.fnCode:
      if x.containsSymbol(y):
        return true
    false
  of crDataList:
    for x in xs.listVal:
      if x.containsSymbol(y):
        return true
    false
  else:
    false

proc sortByDeps(deps: Table[string, CirruData]): seq[string] =
  var depsGraph: Table[string, HashSet[string]]
  var defNames: seq[string]
  for k, v in deps:
    defNames.add(k)
    var depsInfo = initHashSet[string]()
    for k2, v2 in deps:
      if k2 == k:
        continue
      # echo "checking ", k, " -> ", k2, " .. ", v.containsSymbol(k2)
      if v.containsSymbol(k2):
        depsInfo.incl(k2)
    depsGraph[k] = depsInfo
  # echo depsGraph
  for x in defNames.sorted():
    var inserted = false
    for idx, y in result:
      if depsGraph.contains(y) and depsGraph[y].contains(x):
        result.insert(@[x], idx)
        inserted = true
        break
    if inserted:
      continue
    result.add x

proc writeFileIfChanged(filename: string, content: string): bool =
  if fileExists(filename) and readFile(filename) == content:
    return false
  writeFile filename, content
  return true

proc emitJs*(programData: Table[string, ProgramFile], entryNs: string): void =
  if dirExists(jsEmitPath).not:
    createDir(jsEmitPath)

  var unchangedNs: HashSet[string]

  for ns, file in programData:

    # side-effects, reset tracking state
    implicitImports = initTable[string, ImplicitImportItem]()

    if not firstCompilation:
      let appPkgName = entryNs.split('.')[0]
      let pkgName = ns.split('.')[0]
      if appPkgName != pkgName:
        continue # since libraries do not have to be re-compiled

    # let coreLib = "http://js.calcit-lang.org/calcit.core.js".escape()
    let coreLib = "calcit.core".toJsImportName()
    let procsLib = "@calcit/procs".escape()
    var importCode = ""

    var defsCode = "" # code generated by functions
    var valsCode = "" # code generated by thunks

    if ns == "calcit.core":
      importCode = importCode & fmt"{cLine}import {cCurlyL}kwd, wrapTailCall, arrayToList, listToArray{cCurlyR} from {procsLib};{cLine}"
      importCode = importCode & fmt"{cLine}import * as $calcit_procs from {procsLib};{cLine}"
      importCode = importCode & fmt"{cLine}export * from {procsLib};{cLine}"
    else:
      importCode = importCode & fmt"{cLine}import * as $calcit from {coreLib};{cLine}"

    var defNames: HashSet[string] # multiple parts of scoped defs need to be tracked

    # tracking top level scope definitions
    for def in file.defs.keys:
      defNames.incl(def)

    let depsInOrder = sortByDeps(file.defs)
    # echo "deps order: ", depsInOrder

    for def in depsInOrder:
      if ns == "calcit.core":
        # some defs from core can be replaced by calcit.procs
        if preferredJsProc.contains(def):
          defsCode = defsCode & fmt"{cLine}export var {def.escapeVar} = $calcit_procs.{def.escapeVar};{cLine}"
          continue

      let f = file.defs[def]

      case f.kind
      of crDataProc:
        defsCode = defsCode & fmt"{cLine}var {def.escapeVar} = $calcit_procs.{def.escapeVar};{cLine}"
      of crDataFn:
        defsCode = defsCode & genJsFunc(def, f.fnArgs, f.fnCode, ns, true, defNames)
      of crDataThunk:
        # TODO need topological sorting for accuracy
        # values are called directly, put them after fns
        valsCode = valsCode & fmt"{cLine}export var {def.escapeVar} = {f.thunkCode[].toJsCode(ns, defNames)};{cLine}"
      of crDataMacro:
        # macro should be handled during compilation, psuedo code
        defsCode = defsCode & fmt"{cLine}export var {def.escapeVar} = () => {cCurlyL}/* Macro */{cCurlyR};{cLine}"
        defsCode = defsCode & fmt"{cLine}{def.escapeVar}.isMacro = true;{cLine}"
      of crDataSyntax:
        # should he handled inside compiler
        discard
      else:
        echo "[WARNING] strange case for generating a definition ", $f.kind

    if implicitImports.len > 0 and file.ns.isSome():
      let importsInfo = file.ns.get()
      # echo "imports: ", implicitImports
      for def, item in implicitImports:
        # if not importsInfo.contains(def):
        # echo "implicit import ", defNs, "/", def, " in ", ns
        if item.justNs:
          if importsInfo.contains(item.ns).not:
            raiseEvalError("Unknown import: " & item.ns, CirruData(kind: crDataNil))
          let importRule = importsInfo[item.ns]
          let importTarget = if importRule.nsInStr: importRule.ns else: importRule.ns.toJsImportName()
          importCode = importCode & fmt"{cLine}import * as {item.ns.escapeNs} from {importTarget};{cLine}"
        else:
          let importTarget = item.ns.toJsImportName()
          importCode = importCode & fmt"{cLine}import {cCurlyL}{def.escapeVar}{cCurlyR} from {importTarget};{cLine}"

    let jsFilePath = joinPath(jsEmitPath, ns.toJsFileName())
    let wroteNew = writeFileIfChanged(jsFilePath, importCode & cLine & defsCode & cLine & valsCode)
    if wroteNew:
      echo "Emitted js file: ", jsFilePath
    else:
      unchangedNs.incl(ns)

  if unchangedNs.len > 0:
    echo "\n... and " & $(unchangedNs.len) & " files not changed."

  firstCompilation = false
