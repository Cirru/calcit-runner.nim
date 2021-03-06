
import cirru_parser
import ternary_tree

import ../types
import ../data/virtual_list

type CirruEvalError* = ref object of ValueError
  code*: CirruData
  data*: CirruData

proc raiseEvalError*(msg: string, code: CirruData): void =
  var e: CirruEvalError
  new e
  e.msg = msg
  e.code = code

  raise e

proc raiseEvalError*(msg: string, xs: CrVirtualList[CirruData]): void =
  let code = CirruData(kind: crDataList, listVal: xs)
  raiseEvalError(msg, code)

proc raiseEvalError*(msg: string, xs: seq[CirruData]): void =
  let code = CirruData(kind: crDataList, listVal: initCrVirtualList(xs))
  raiseEvalError(msg, code)

proc raiseEvalErrorData*(msg: string, code: seq[CirruData], data: CirruData): void =
  var e: CirruEvalError
  new e
  e.msg = msg
  e.code = CirruData(kind: crDataList, listVal: initCrVirtualList(code))
  e.data = data
  raise e
