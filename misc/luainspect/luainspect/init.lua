-- luainspect.init - core LuaInspect source analysis.
--
-- This module is a bit more high level than luainspect.ast.  It deals more with
-- interpretation/inference of semantics of an AST.  It also uses luainspect.globals,
-- which does the basic semantic interpretation of globals/locals.
--
-- (c) 2010 David Manura, MIT License.

local M = {}

-- This is the API version.  It is an ISO8601 date expressed as a fraction.
M.APIVERSION = 0.20100805

local LA = require "luainspect.ast"
local LG = require "luainspect.globals"
local LS = require "luainspect.signatures"
local T = require "luainspect.types"

--! require 'luainspect.typecheck' (context)
 
local ENABLE_RETURN_ANALYSIS = false
local DETECT_DEADCODE = false


-- Functional forms of Lua operators.
local ops = {}
ops["add"] = function(a,b) return a+b end
ops["sub"] = function(a,b) return a-b end
ops["mul"] = function(a,b) return a*b end
ops["div"] = function(a,b) return a/b end
ops["mod"] = function(a,b) return a%b end
ops["pow"] = function(a,b) return a^b end
ops["concat"] = function(a,b) return a..b end
ops["eq"] = function(a,b) return a==b end
ops["lt"] = function(a,b) return a<b end
ops["le"] = function(a,b) return a<=b end
ops["and"] = function(a,b) return a and b end
ops["or"] = function(a,b) return a or b end
ops["not"] = function(a) return not a end
ops["len"] = function(a) return #a end
ops["unm"] = function(a) return -a end


-- Perform binary operation.  Supports types.
local function dobinop(opid, a, b)
  if (a == T.number or b == T.number) and
     (a == T.number or type(a) == 'number' ) and
     (b == T.number or type(b) == 'number' )
  then
    if opid == 'eq' or opid == 'lt' or opid == 'le' then
      return T.boolean
    elseif opid == 'concat' then
      return T.string
    else
      return T.number
    end
  elseif (a == T.string or b == T.string) and
           (a == T.string or type(a) == 'string' ) and
           (b == T.string or type(b) == 'string' )
  then
    if opid == 'concat' or opid == 'and' or opid == 'or' then
      return T.string
    elseif opid == 'eq' or opid == 'lt' or opid == 'le' then
      return T.boolean
    else
      return T.number
    end
  elseif (a == T.boolean or b == T.boolean) and
           (a == T.boolean or type(a) == 'boolean' ) and
           (b == T.boolean or type(b) == 'boolean' )
  then
    if opid == 'eq' or opid == 'and' or opid == 'or' then
      return T.boolean
    else
      error('invalid operation on booleans: ' .. opid, 0)
    end
  elseif T.istype[a] or T.istype[b] then
    return T.universal
  else
    return ops[opid](a, b)
  end
end


-- Perform unary operation.  Supports types.
local function dounop(opid, a)
  if opid == 'not' then
    if T.istype[a] then
      return T.boolean
    else
      return ops[opid](a)
    end
  elseif a == T.number then
    if opid == 'unm' then
      return T.number
    else -- 'len'
      error('invalid operation on number: ' .. opid, 0)
    end
  elseif a == T.string then
    return T.number
  elseif a == T.boolean then
    error('invalid operation on boolean: ' .. opid, 0)
  elseif T.istype[a] then
    return nil, 'unknown'
  else
    return ops[opid](a)
  end
end

-- Like info in debug.getinfo but inferred by static analysis.
-- object -> {fpos=fpos, source="@" .. source, fast=ast, tokenlist=tokenlist}
-- Careful: value may reference key (affects pre-5.2 which lacks emphemerons).
--   See also ast.nocollect.
M.debuginfo = setmetatable({}, {__mode='v'})

-- Modules loaded via require_inspect.
-- module name string -> AST node
-- note: no weak refs
M.package_loaded = {}

-- Stringifies interpreted value for debugging.
-- CATEGORY: debug
local function debugvalue(ast)
  local s
  if ast then
    s = ast.value ~= T.universal and 'known:' .. tostring(ast.value) or 'unknown'
  else
    s = '?'
  end
  return s
end


-- Read contents of text file in path, in binary mode.
-- On error, returns nil and error message.
local function readfile(path)
  local fh, err = io.open(path, 'rb')
  if fh then
    local data; data, err = fh:read'*a'
    if data then return data end
  end
  return nil, err
end

-- Similar to string.gsub but with plain replacement (similar to option in string.match)
-- http://lua-users.org/lists/lua-l/2002-04/msg00118.html
-- CATEGORY: utility/string
local function plain_gsub(s, pattern, repl)
  repl = repl:gsub('(%W)', '%%%1')
  return s:gsub(pattern, repl)
end

-- Loads source code of given module name.
-- Returns code followed by path.
-- CATEGORY: utility/package
local function load_module_source(name)
  for spec in package.path:gmatch'[^;]+' do
    local testpath = plain_gsub(spec, '%?', (name:gsub('%.', '/')))
    local src, err_ = readfile(testpath)
    if src then return src, testpath end
  end
  return nil
end


-- Clears global state.
-- This includes cached inspected modules.
function M.clear_cache()
  for k,v in pairs(M.package_loaded) do
    M.package_loaded[k] = nil
  end
end


-- Gets all keywords related to AST `ast`, where `top_ast` is the root of `ast`
-- and `src` is source code of `top_ast`
-- Related keywords are defined as all keywords directly associated with block containing node
-- `ast`.  Furthermore, break statements are related to containing loop statements,
-- and return statements are related to containing function statement (if any).
-- function declaration syntactic sugar is handled specially too to ensure the 'function' keyword
-- is highlighted even though it may be outside of the `Function AST.
--
-- Returns token list or nil if not applicable.  Returned `ast` is AST containing related keywords.
-- CATEGORY: keyword comprehension
local iskeystat = {Do=true, While=true, Repeat=true, If=true, Fornum=true, Forin=true,
    Local=true, Localrec=true, Return=true, Break=true, Function=true,
    Set=true -- note: Set for `function name`
}
local isloop = {While=true, Repeat=true, Fornum=true, Forin=true}
local isblock = {Do=true, While=true, Repeat=true, If=true, Fornum=true, Forin=true, Function=true}
function M.related_keywords(ast, top_ast, tokenlist, src)
  -- Expand or contract AST for certain contained statements.
  local more
  if ast.tag == 'Return' then
    -- if `return` selected, that consider containing function selected (if any)
    if not ast.parent then LA.mark_parents(top_ast) end
    local ancestor_ast = ast.parent
    while ancestor_ast ~= nil and ancestor_ast.tag ~= 'Function' do
      ancestor_ast = ancestor_ast.parent
    end
    if ancestor_ast then ast = ancestor_ast end -- but only change if exists
  elseif ast.tag == 'Break' then
    -- if `break` selected, that consider containing loop selected
    if not ast.parent then LA.mark_parents(top_ast) end
    local ancestor_ast = ast.parent
    while ancestor_ast ~= nil and not isloop[ancestor_ast.tag] do
      ancestor_ast = ancestor_ast.parent
    end
    ast = ancestor_ast
  elseif ast.tag == 'Set' then
    local val1_ast = ast[2][1]
    if val1_ast.tag == 'Function' then
      local token = tokenlist[LA.ast_idx_range_in_tokenlist(tokenlist, ast)]
      if token.tag == 'Keyword' and token[1] == 'function' then -- function with syntactic sugar `function f`
        ast = ast[2][1] -- select `Function node
      else
        more = true
      end
    else
      more = true
    end
  elseif ast.tag == 'Localrec' and ast[2][1].tag == 'Function' then
    -- if `local function f` selected, which becomes a `Localrec, consider `Function node.
    ast = ast[2][1]
    --IMPROVE: only contract ast if `function` part of `local function` is selected.
  else
    more = true
  end
  if more then -- not yet handled
    -- Consider containing block.
    if not ast.parent then LA.mark_parents(top_ast) end
    local ancestor_ast = ast
    while ancestor_ast ~= top_ast and not isblock[ancestor_ast.tag] do
      ancestor_ast = ancestor_ast.parent
    end
    ast = ancestor_ast
  end

  --  keywords in statement/block.    
  if iskeystat[ast.tag] then
    local keywords = {}
    for i=1,#tokenlist do
     local token = tokenlist[i]
     if token.ast == ast and token.tag == 'Keyword' then
       keywords[#keywords+1] = token
     end
    end

    -- Expand keywords for certaining statements.
    if ast.tag == 'Function' then
      -- if `Function, also select 'function' and 'return' keywords
      local function f(ast)
        for _,cast in ipairs(ast) do
          if type(cast) == 'table' then
            if cast.tag == 'Return' then
              local token = tokenlist[LA.ast_idx_range_in_tokenlist(tokenlist, cast)]
              keywords[#keywords+1] = token
            elseif cast.tag ~= 'Function' then f(cast) end
          end
        end
      end
      f(ast)
      if not ast.parent then LA.mark_parents(top_ast) end
      local grand_ast = ast.parent.parent
      if grand_ast.tag == 'Set' then
        local token = tokenlist[LA.ast_idx_range_in_tokenlist(tokenlist, grand_ast)]
        if token.tag == 'Keyword' and token[1] == 'function' then
          keywords[#keywords+1] = token
        end
      elseif grand_ast.tag == 'Localrec' then
        local tidx = LA.ast_idx_range_in_tokenlist(tokenlist, grand_ast)
        repeat tidx = tidx + 1 until tokenlist[tidx].tag == 'Keyword' and tokenlist[tidx][1] == 'function'
        local token = tokenlist[tidx]
        keywords[#keywords+1] = token
      end
    elseif isloop[ast.tag] then
      -- if loop, also select 'break' keywords
      local function f(ast)
        for _,cast in ipairs(ast) do
          if type(cast) == 'table' then
            if cast.tag == 'Break' then
              local tidx = LA.ast_idx_range_in_tokenlist(tokenlist, cast)
              keywords[#keywords+1] = tokenlist[tidx]
            elseif not isloop[cast.tag]  then f(cast) end
          end
        end
      end
      f(ast)        
    end
    
    return keywords, ast
  end
  return nil, ast
end


-- Mark tokenlist (top_ast/tokenlist/src) with keywordid AST attributes.
-- All keywords related to each other have the same keyword ID integer.
-- NOTE: This is not done/undone by inspect/uninspect.
-- CATEGORY: keyword comprehension
function M.mark_related_keywords(top_ast, tokenlist, src)
  local id = 0
  local idof = {}
  for _, token in ipairs(tokenlist) do
    if token.tag == 'Keyword' and not idof[token] then
      id = id + 1
      local match_ast =
        LA.smallest_ast_containing_range(top_ast, tokenlist, src, token.fpos, token.lpos)
      local ktokenlist = M.related_keywords(match_ast, top_ast, tokenlist, src)
      if ktokenlist then
         for _, ktoken in ipairs(ktokenlist) do
          ktoken.keywordid = id
          idof[ktoken] = true
        end
      end
      -- note: related_keywords may return a keyword set not containing given keyword.
    end
  end
end


-- function for t[k]
local function tindex(t, k) return t[k] end

local unescape = {['d'] = '.'}



-- Set known value on ast to that on src_ast.
-- CATEGORY: utility function for infer_values.
local function set_value(ast, src_ast)
  if not ast.isvaluepegged then
    ast.value = src_ast.value
  end
end


local function known(o)
  return not T.istype[o]
end
local function unknown(o)
  return T.istype[o]
end


-- CATEGORY: utility function for infer_values.
local function tastnewindex(t_ast, k_ast, v_ast)
  if known(t_ast.value) and known(k_ast.value) and known(v_ast.value) then
    local t, k, v = t_ast.value, k_ast.value, v_ast.value
    if t[k] ~= nil and v ~= t[k] then -- multiple values
      return T.universal
    else
      t[k] = v
      return v
    end
  else
    return T.universal
  end
end


-- Get expected number of parameters for function (min, max) values.
-- In case of vararg, max is unknown and set to nil.
local function function_param_range(ast)
  local names_ast = ast[1]
  if #names_ast >= 1 and names_ast[#names_ast].tag == 'Dots' then
    return #names_ast-1, nil
  else
    return #names_ast, #names_ast
  end
end

-- Gets number of arguments to function call: (min, max) range.
-- In case of trailing vararg or function call, max is unknown and set to nil.
local function call_arg_range(ast)
  if ast.tag == 'Invoke' then
    if #ast >= 3 and
      (ast[#ast].tag == 'Dots' or ast[#ast].tag == 'Call' or ast[#ast].tag == 'Invoke')
    then
      return #ast-2, nil
    else
      return #ast-1, #ast-1
    end    
  else
    if #ast >= 2 and
      (ast[#ast].tag == 'Dots' or ast[#ast].tag == 'Call' or ast[#ast].tag == 'Invoke')
    then
      return #ast-2, nil
    else
      return #ast-1, #ast-1
    end
  end
end


-- Reports warning. List of strings.
local function warn(report, ...)
  report('warning: ' .. table.concat({...}, ' '))
end

-- Reports status messages. List of strings.
local function status(report, ...)
  report('status: ' .. table.concat({...}, ' '))
end

-- unique value used to detect require loops (A require B require A)
local REQUIRE_SENTINEL = function() end

-- Version of require that does source analysis (inspect) on module.
function M.require_inspect(name, report)
  local ast = M.package_loaded[name]
  if ast == REQUIRE_SENTINEL then
     warn(report, "loop in require when loading " .. name)
     return nil
  end
  if ast then return ast end
  status(report, 'loading:' .. name)
  M.package_loaded[name] = REQUIRE_SENTINEL -- avoid recursion on require loops
  local msrc, mpath = load_module_source(name)
  local vinfo
  if msrc then
    local mast, err = LA.ast_from_string(msrc, mpath)
    if mast then
      local mtokenlist = LA.ast_to_tokenlist(mast, msrc)
      M.inspect(mast, mtokenlist, report)
      if ENABLE_RETURN_ANALYSIS then
        vinfo = mast
      else
        if mast[#mast] and mast[#mast].tag == 'Return' and mast[#mast][1] then
          vinfo = mast[#mast][1]
        else
          vinfo = T.universal
        end
      end
    else
      vinfo = {value=T.error(err)}
      warn(report, err, " ", mpath) --Q:error printing good?
    end
  else
    warn(report, 'module not found: ' .. name)
    vinfo = {value=T.error'module not found'} --IMPROVE: include search paths?
  end
  M.package_loaded[name] = vinfo
  return vinfo
end


-- Mark AST node and all children as dead (ast.isdead).
local function mark_dead(ast)
  LA.walk(ast, function(bast) bast.isdead = true end)
end

-- Gets list of `Return statement ASTs in `Function (or chunk) f_ast, not including
-- return's in nested functions.  Also returns boolean `has_implicit` indicating
-- whether function may return by exiting the function without a return statement.
-- Returns that are never exected are omitted (e.g. last return is omitted in
-- `function f() if x then return 1 else return 2 end return 3 end`).
-- Also marks AST nodes with ast.isdead (dead-code).
local function get_func_returns(f_ast)
  local isalwaysreturn = {}
  local returns = {}
  local function f(ast, isdead)
    for _,cast in ipairs(ast) do if type(cast) == 'table' then
      if isdead then mark_dead(cast) end
      if cast.tag ~= 'Function' and not isdead then -- skip nested functions
        f(cast, isdead) -- depth-first traverse
      end
      if ast.tag ~= 'If' and isalwaysreturn[cast] then isdead = true end
        -- subsequent statements in block never executed
    end end
    
    -- Code on walking up AST: propagate children to parents
    if ast.tag == 'Return' then
      returns[#returns+1] = ast
      isalwaysreturn[ast] = true
    elseif ast.tag == 'If' then
      if #ast%2 ~= 0 then -- has 'else' block
        local isreturn = true
        for i=2,#ast do
          if (i%2==0 or i==#ast) and not isalwaysreturn[ast[i]] then isreturn = nil; break end
        end
        isalwaysreturn[ast] = isreturn
      end
    else -- note: iterates not just blocks, but should be ok
      for i=1,#ast do
        if isalwaysreturn[ast[i]] then
          isalwaysreturn[ast] = true; break
        end
      end
    end
  end
  f(f_ast, false)
  local block_ast = f_ast[2]
  local has_implicit = not isalwaysreturn[block_ast]
  return returns, has_implicit
end

-- temporary hack?
local function valnode_normalize(valnode)
  if valnode then
    return valnode.value
  else
    return T.none
  end
end


-- Gets return value at given return argument index, given list of `Return statements.
-- Return value is a superset of corresponding types in list of statements.
-- Example: {`Return{1,2,3}, `Return{1,3,'z'}} would return
-- 1, T.number, and T.universal for retidx 1, 2 and 3 respectively.
local function get_return_value(returns, retidx)
  if #returns == 0 then return T.none
  elseif #returns == 1 then
    return valnode_normalize(returns[1][retidx])
  else
    local combined_value = valnode_normalize(returns[1][retidx])
    for i=2,#returns do
      local cur_value = valnode_normalize(returns[i][retidx])
      combined_value = T.superset_types(combined_value, cur_value)
      if combined_value == T.universal then -- can't expand set further
          return combined_value
      end
    end
    return combined_value
    --TODO: handle values with possibly any number of return values, like f()
  end
end


-- Gets return values (or types) on `Function (or chunk) represented by given AST.
local function get_func_return_values(f_ast)
  local returns, has_implicit = get_func_returns(f_ast)
  if has_implicit then returns[#returns+1] = {tag='Return'} end

  local returnvals = {}
  for retidx=1,math.huge do
    local value = get_return_value(returns, retidx)
    if value == T.none then break end
    returnvals[#returnvals+1] = value
  end
  return returnvals
end
-- Example: AST of `function(x) if x then return 1,2,3 else return 1,3,"z" end end`
-- returns {1, T.number, T.universal}.


-- Infer values of variables. Also marks dead code (ast.isdead).
--FIX/WARNING - this probably needs more work
-- Sets top_ast.valueglobals, ast.value, ast.idxvalue
-- CATEGORY: code interpretation
local nil_value_ast = {}
function M.infer_values(top_ast, tokenlist, report)
  if not top_ast.valueglobals then top_ast.valueglobals = {} end
  

  -- infer values
  LA.walk(top_ast, nil, function(ast) -- walk up
    -- process `require` statements.
    if ast.tag == 'Local' or ast.tag == 'Localrec' then
      local vars_ast, values_ast = ast[1], ast[2]
      for i=1,#vars_ast do
        local var_ast, value_ast = vars_ast[i], values_ast[i]
        value_ast = value_ast or nil_value_ast
        set_value(var_ast, value_ast)
        --FIX: handle functions with multiple returns
      end
    elseif ast.tag == 'Set' then
      local vars_ast, values_ast = ast[1], ast[2]
      for i=1,#vars_ast do
        local var_ast, value_ast = vars_ast[i], values_ast[i]
        value_ast = value_ast or nil_value_ast
        if var_ast.tag == 'Index' then
          local ok;  ok, var_ast.value = pcall(tastnewindex, var_ast[1], var_ast[2], value_ast)
          if not ok then var_ast.value = T.error(var_ast.value) end
            --FIX: propagate to localdefinition?
        else
          assert(var_ast.tag == 'Id', var_ast.tag)
          if var_ast.localdefinition then
            set_value(var_ast, value_ast)
          else -- global
            --old:if known(value_ast.value) then
              local name, val = var_ast[1], value_ast.value
              top_ast.valueglobals[name] = val
            --end
          end
        end --FIX: handle functions with multiple returns
        --FIX: propagate to definition or localdefinition?
      end
    elseif ast.tag == 'Id' then
      if ast.localdefinition then
        local localdefinition = ast.localdefinition
        if not localdefinition.isset then -- IMPROVE: support non-const (isset false) too
          set_value(ast, localdefinition)
        end
      else -- global
        local name = ast[1]
        local v = top_ast.valueglobals[name]
        if v ~= nil then
          ast.value = v
        else
          local ok; ok, ast.value = pcall(tindex, _G, ast[1])
          if not ok then ast.value = T.error(ast.value) end
        end
      end
    elseif ast.tag == 'Index' then
      local t_ast, k_ast = ast[1], ast[2]
      if known(t_ast.value) and known(k_ast.value) then
        local ok; ok, ast.value = pcall(tindex, t_ast.value, k_ast.value)
        if not ok then ast.value = T.error(ast.value) end
      end
    elseif ast.tag == 'Call' then
      local func_ast = ast[1]
      local args_known = true
      for i=2,#ast do if unknown(ast[i].value) then args_known = false; break end end
      local found
      if known(func_ast.value) and args_known then
        local values_concrete = true
        for i=1,#ast do if unknown(ast[i].value) then values_concrete = false; break end end
        local func = func_ast.value
        if func == require and known(ast[2].value) then
          local rast = M.require_inspect(ast[2].value, report)
          if rast and known(rast.value) then
            ast.value = rast.value
            found = true
          end
        end
        if not found and LS.safe_function[func] then
          local values = {}; for i=1,#ast-1 do values[i] = ast[i+1].value end
          local ok; ok, ast.value = pcall(func, unpack(values,1,#ast-1))
          if not ok then ast.value = T.error(ast.value) end
          --TODO: handle multiple return values
          found = true
        end
      end
      if not found then
        local mf = LS.mock_functions[func_ast.value]
        if mf then
          local o1 = mf.outputs[1] -- IMPROVE: handle multiple returns
          ast.value = o1
        else
          local info = M.debuginfo[func_ast.value]
          local retvals = info and info.retvals
          if retvals then
            ast.value = retvals[1]
          end
          --TODO:handle multiple return values
        end
      end
    elseif ast.tag == 'Invoke' then
      local t_ast, k_ast = ast[1], ast[2]
      if known(t_ast.value) and known(k_ast.value) then
        local ok; ok, ast.idxvalue = pcall(tindex, t_ast.value, k_ast.value)
        if not ok then ast.idxvalue = T.error(ast.idxvalue) end
      end

      -- note: similar to 'Call' code
      local args_known = true
      for i=3,#ast do if unknown(ast[i].value) then args_known = false; break end end
      if known(ast.idxvalue) and args_known then
        local func = ast.idxvalue
        if LS.safe_function[func] then
          local values = {}; for i=1,#ast-2 do values[i] = ast[i+2].value end
          local ok; ok, ast.value = pcall(func, t_ast.value, unpack(values,1,#ast-2))
          if not ok then ast.value = T.error(ast.value) end
          --TODO: handle multiple return values
        end
      end
      if unknown(ast.value) then
        local mf = LS.mock_functions[ast.idxvalue]
        if mf then
          local o1 = mf.outputs[1] -- IMPROVE: handle multiple returns
          ast.value = o1
        end
      end
    elseif ast.tag == 'String' or ast.tag == 'Number' then
      ast.value = ast[1]
    elseif ast.tag == 'True' or ast.tag == 'False' then
      ast.value = (ast.tag == 'True')
    elseif ast.tag == 'Function' or ast == top_ast then -- includes chunk
      if ast.value == nil then -- avoid redefinition
        local x
        local val = function() x=nil end
        local fpos = LA.ast_pos_range(ast, tokenlist)
        local source = ast.lineinfo.first[4] -- a HACK? relies on AST lineinfo
        local retvals
        if ENABLE_RETURN_ANALYSIS then
          retvals = get_func_return_values(ast) --Q:move outside of containing conditional?
        end
        local info = {fpos=fpos, source="@" .. source, fast=ast, tokenlist=tokenlist, retvals=retvals}
        M.debuginfo[val] = info
        ast.value = val
        ast.nocollect = info -- prevents garbage collection while ast exists
      end
    elseif ast.tag == 'Table' then
      if ast.value == nil then -- avoid redefinition
        local value = {}
        local n = 1
        for _,east in ipairs(ast) do
          if east.tag == 'Pair' then
            local kast, vast = east[1], east[2]
            if known(kast.value) and known(vast.value) then
              value[kast.value] = vast.value
            end
          else
            if known(east.value) then
              value[n] = east.value
            end
            n = n + 1
          end
        end
        --table.foreach(value, print)
        ast.value = value
      end
    elseif ast.tag == 'Paren' then
      ast.value = ast[1].value
    elseif ast.tag == 'Op' then
      local opid, aast, bast = ast[1], ast[2], ast[3]
      local ok
      if bast then
        ok, ast.value = pcall(dobinop, opid, aast.value, bast.value)
      else
        ok, ast.value = pcall(dounop, opid, aast.value)
      end
      if not ok then ast.value = T.error(ast.value) end
    elseif ast.tag == 'If' then
      -- detect dead-code
      if DETECT_DEADCODE then
        for i=2,#ast,2 do local valnode = ast[i-1]
          local bval = T.boolean_cast(valnode.value)
          if bval == false then -- certainly false
            mark_dead(ast[i])
          elseif bval == true then -- certainly true
            for ii=i+1,#ast do if ii%2 == 0 or ii==#ast then -- following blocks are dead
              mark_dead(ast[ii])
            end end
            break
          end
        end
      end
      -- IMPROVE? `if true return end; f()` - f could be marked as deadcode
    elseif ast.tag == 'While' then
      -- detect dead-code
      if DETECT_DEADCODE then
        local expr_ast, body_ast = ast[1], ast[2]
        if T.boolean_cast(expr_ast.value) == false then
          mark_dead(body_ast)
        end
      end
    end
  end)
end


-- Label variables with unique identifiers.
-- Sets ast.id, ast.resolvedname
-- CATEGORY: code interpretation
function M.mark_identifiers(ast)
  local id = 0
  local seen_globals = {}
  LA.walk(ast, function(ast)
    if ast.tag == 'Id' or ast.isfield then
      if ast.localdefinition then
        if ast.localdefinition == ast then -- lexical definition
          id = id + 1
          ast.id = id
        else
          ast.id = ast.localdefinition.id
        end
      elseif ast.isfield then
        local previousid = ast.previous.id
        if not previousid then -- note: ("abc"):upper() has no previous ID
          id = id + 1
          previousid = id
        end
        local name = previousid .. '.' .. ast[1]:gsub('%%', '%%'):gsub('%.', '%d')
        if not seen_globals[name] then
          id = id + 1
          seen_globals[name] = id
        end
        ast.id = seen_globals[name]

        -- also resolve name
        local previousresolvedname = ast.previous.resolvedname
        if previousresolvedname then
          ast.resolvedname = previousresolvedname .. '.' .. ast[1]:gsub('%%', '%%'):gsub('%.', '%d')
        end
      else -- global
        local name = ast[1]
        if not seen_globals[name] then
          id = id + 1
          seen_globals[name] = id
        end
        ast.id = seen_globals[name]

        -- also resolve name
        ast.resolvedname = ast[1]
      end
    end
  end)
end


-- Environment in which to execute special comments (see below).
local env = setmetatable({}, {__index=_G})
env.context = env

env.number = T.number
env.string = T.string
env.boolean = T.boolean
env.error = T.error


-- Apply value to all identifiers with name matching pattern.
-- This command is callable inside special comments.
-- CATEGORY: code interpretation / special comment command
function env.apply_value(pattern, val)
  local function f(ast)
    if ast.tag == 'Id' and ast[1]:match(pattern) then
      ast.value = val; ast.isvaluepegged = true
    end
    for _,bast in ipairs(ast) do
      if type(bast) == 'table' then
        f(bast)
      end
    end
  end
  f(ast) -- ast from environment
  --UNUSED:
  -- for i=env.asti, #env.ast do
  --  local bast = env.ast[i]
  --  if type(bast) == 'table' then f(bast) end
  --end
end
setfenv(env.apply_value, env)


-- Evaluate all special comments (i.e. comments prefixed by '!') in code.
-- This is similar to luaanalyze.
-- CATEGORY: code interpretation / special comments
function M.eval_comments(ast, tokenlist, report)
  local function eval(command, ast)
    --DEBUG('!', command:gsub('%s+$', ''), ast.tag)
    local f, err = loadstring(command)
    if f then
      setfenv(f, env); env.ast = ast
      local ok, err = pcall(f, ast)
      if not ok then warn(report, err, ': ', command) end
      env.ast = nil
   else
     warn(report, err, ': ', command)
    end
  end

  for idx=1,#tokenlist do
    local token = tokenlist[idx]
    if token.tag == 'Comment' then
      local command = token[1]:match'^!(.*)'
      if command then
        local mast = LA.smallest_ast_containing_range(ast, tokenlist, nil, token.fpos, token.lpos)
        eval(command, mast)
      end
    end
  end
end
--IMPROVE: in `do f() --[[!g()]] h()` only apply g to h.




-- Partially undoes effects of inspect().
-- Note: does not undo mark_tag2 and mark_parents (see replace_statements).
-- CATEGORY: code interpretation
function M.uninspect(top_ast)
  LA.walk(top_ast, function(ast)
    -- undo inspect_globals.globals
    ast.localdefinition = nil
    ast.functionlevel = nil
    ast.isparam = nil
    ast.isset = nil
    ast.isused = nil
    ast.isfield = nil
    ast.previous = nil
    ast.localmasked = nil
    ast.localmasking = nil
  
    -- undo mark_identifiers
    ast.id = nil
    ast.resolvedname = nil
    
    -- undo infer_values
    ast.value = nil
    ast.idxvalue = nil
    ast.isdead = nil   -- via get_func_returns
    ast.isvaluepegged = nil
    
    -- undo walk setting ast.seevalue
    ast.seevalue = nil
    
    -- undo walk setting ast.definedglobal
    ast.definedglobal = nil

    -- undo notes
    ast.note = nil
    
    ast.nocollect = nil
  end)
  
  -- undo infer_values
  top_ast.valueglobals = nil
end


-- Main inspection routine.  Inspects top_ast/tokenlist.
-- Error/status messages are sent to function `report`.
-- CATEGORY: code interpretation
function M.inspect(top_ast, tokenlist, report)
  --DEBUG: local t0 = os.clock()
  
  report = report or function() end
  
  local globals = LG.globals(top_ast)
 
  M.mark_identifiers(top_ast)

  M.eval_comments(top_ast, tokenlist, report)
  
  M.infer_values(top_ast, tokenlist, report)
  M.infer_values(top_ast, tokenlist, report) -- two passes to handle forward declarations of globals (IMPROVE: more passes?)
  
  -- Make some nodes as having values related to its parent.
  -- This allows clicking on `bar` in `foo.bar` to display
  -- the value of `foo.bar` rather than just "bar".
  LA.walk(top_ast, function(ast)
    if ast.tag == "Index" then
      ast[2].seevalue = ast
    elseif ast.tag == "Invoke" then
      ast[2].seevalue = {value=ast.idxvalue, parent=ast}
    end
  end)

  local function eval_name_helper(name)
    local var = _G
    for part in (name .. '.'):gmatch("([^.]*)%.") do
      part = part:gsub('%%(.)', unescape)
      if type(var) ~= 'table' and type(var) ~= 'userdata' then return nil end  --TODO:improve?
      var = var[part]
      if var == nil then return nil end
    end
    return var
  end
  local function eval_name(name)
    local ok, o = pcall(eval_name_helper, name)
    if ok then return o else return nil end
  end
  
  LA.walk(top_ast, function(ast)
    if ast.tag == 'Id' or ast.isfield then
      local vname = ast[1]
      --TODO: rename definedglobal to definedfield for clarity
      local atype = ast.localdefinition and 'local' or ast.isfield and 'field' or 'global'
      local definedglobal = ast.resolvedname and eval_name(ast.resolvedname) ~= nil or
                 atype == 'global' and (globals[vname] and globals[vname].set) or nil
      ast.definedglobal = definedglobal
      -- FIX: _G includes modules imported by inspect.lua, which is not desired
    elseif ast.tag == 'Call' or ast.tag == 'Invoke' then
      -- Argument count check.
      local value = ast.idxvalue or ast[1].value
      local info = M.debuginfo[value]
      local fast = info and info.fast
      if fast or LS.argument_counts[value] then
        local nparammin, nparammax
        if fast then
          nparammin, nparammax = function_param_range(info.fast)
        else
          nparammin, nparammax = unpack(LS.argument_counts[value])
        end
        local nargmin, nargmax = call_arg_range(ast)
        --print('DEBUG:', nparammin, nparammax, nargmin, nargmax)
        local iswarn
        local target_ast = ast.tag == 'Call' and ast[1] or ast[2]
        if (nargmax or math.huge) < nparammin then
          ast.note = "Too few arguments.  "
          iswarn = true
        elseif nargmin > (nparammax or math.huge) then
          ast.note = "Too many arguments.  "
          iswarn = true
        end
        if iswarn then
          ast.note = ast.note ..  "Expected "
            .. nparammin .. (nparammax == nparammin and "" or " to " .. (nparammax or "infinity"))
            .. " but got "
            .. nargmin .. (nargmax == nargmin and "" or " to " .. (nargmax or "infinity")) .. "."
        end
      end
    end
  end)
end


-- Resolve identifier to value [*]
function M.resolve_id(id, scope, valueglobals, _G)
  local val
  if scope[id] then
    val = scope[id].value
  elseif valueglobals[id] ~= nil then
    val = valueglobals[id]
  else
    val = _G[id] -- assumes not raise
  end
  return val
end

-- Resolve prefix chain expression to value. [*]
-- On error returns nil and error object
function M.resolve_prefixexp(ids, scope, valueglobals, _G)
  local val = M.resolve_id(ids[1], scope, valueglobals, _G)
  local ok, err = pcall(function()
    for i=2,#ids do
      val = val[ids[i]]
    end
  end)
  if err then return nil, err or '?' end
  return val
end

-- Get local scope at given 1-indexed char position
function M.get_scope(pos1, ast, tokenlist)
  local mast, isafter = LA.current_statementblock(ast, tokenlist, pos1)
  local scope = LG.variables_in_scope(mast, isafter)
  return scope
end

-- Gets names in prefix expression ids (as returned by resolve_prefixexp). [*]
function M.names_in_prefixexp(ids, pos, ast, tokenlist)
  local scope = M.get_scope(pos, ast, tokenlist)
  --FIX: above does not handle `for x=1,2 do| print(x) end` where '|' is cursor position.
  local names = {}
  if #ids == 0 then -- global
    for name in pairs(scope) do names[#names+1] = name end
    for name in pairs(ast.valueglobals) do names[#names+1] = name end
    for name in pairs(_G) do names[#names+1] = name end
  else  -- field
    local t, err_ = M.resolve_prefixexp(ids, scope, ast.valueglobals, _G)
    if type(t) == 'table' then  -- note: err_ implies false here
      for name in pairs(t) do names[#names+1] = name end
    end
  end
  return names
end

-- Gets signature (function argument string or helpinfo string) on value.
-- Returns nil on not found.
function M.get_signature_of_value(value)
  local info = M.debuginfo[value] -- first try this
  if info and info.fast then
    local fidx, lidx = LA.ast_idx_range_in_tokenlist(info.tokenlist, info.fast[1])
    local ts = {}
    if fidx then
      for i=fidx,lidx do
        local token = info.tokenlist[i]
        ts[#ts+1] = token.tag == 'Dots' and '...' or token[1]
      end
    end
    local sig = 'function(' .. table.concat(ts, ' ') .. ')'
    if info.retvals then
      local vals = info.retvals
      local ts = {}
      if #vals == 0 then
        sig = sig .. " no returns"
      else
        for i=1,#vals do local val = vals[i]
          ts[#ts+1] = T.istype[val] and tostring(val) or LA.dumpstring(val) --Q:dumpstring too verbose?
        end
        sig = sig .. " returns " .. table.concat(ts, ", ")
      end
    end
    return sig
  end
  local sig = LS.value_signatures[value] -- else try this
  return sig
end


-- Gets signature (function argument string or helpinfo string) on variable ast.
-- Returns nil on not found.
function M.get_signature(ast)
  if known(ast.value) then
    return M.get_signature_of_value(ast.value)
  end
end


-- Gets 1-indexed character (or line) position and filename of
-- definition associated with AST node (if any).
function M.ast_to_definition_position(ast, tokenlist)
  local local_ast = ast.localdefinition
  local fpos, fline, path
  if local_ast then
    local tidx = LA.ast_idx_range_in_tokenlist(tokenlist, local_ast)
    if tidx then
      local spath = ast.lineinfo.first[4] -- a HACK? using lineinfo
      fpos = tokenlist[tidx].fpos; path = spath
    end
  end
  if not fpos then
    local valueast = ast.seevalue or ast
    local val = valueast and valueast.value
    local info = M.debuginfo[val] or type(val) == 'function' and debug.getinfo(val)
    if info then
      if info.source:match'^@' then
        path = info.source:match'@(.*)'
        if info.linedefined then
          fline = info.linedefined
        else
          fpos = info.fpos
        end
      end
    end
  end
  return fpos, fline, path
end


-- Returns true iff value in ast node is known in some way.
function M.is_known_value(ast)
  local vast = ast.seevalue or ast
  return vast.definedglobal or known(vast.value) and vast.value ~= nil
end


-- Get details information about value in AST node, as string.
function M.get_value_details(ast, tokenlist, src)
  local info = ""

  if not ast then return '?' end

  local vast = ast.seevalue or ast
  
  if ast.localdefinition then
    if not ast.localdefinition.isused then info = info .. "unused " end
    if ast.localdefinition.isset then info = info .. "mutable " end
    if ast.localdefinition.functionlevel < ast.functionlevel then
      info = info .. "upvalue "
    elseif ast.localdefinition.isparam then
      info = info .. "function parameter "
    else
      info = info .. "local "
    end

    if ast.localmasking then
      info = info .. "masking "
      local fpos = LA.ast_pos_range(ast.localmasking, tokenlist)
      if fpos then
        local linenum = LA.pos_to_linecol(fpos, src)
        info = info .. "definition at line " .. linenum .. " "
      end
    end
    if ast.localmasked then
      info = info .. "masked "
    end
  elseif ast.tag == 'Id' then -- global
    info = info .. (M.is_known_value(vast) and "known" or "unknown")
    info = info .. " global "
  elseif ast.isfield then
    info = info .. (M.is_known_value(vast) and "known" or "unknown")
    info = info .. " field "
  else
    info = info .. "? "
  end

  info = info .. "\nvalue: " .. tostring(vast.value) .. " "
 
  local sig = M.get_signature(vast)
  if sig then
    local kind = sig:find '%w%s*%b()$'  and 'signature' or 'description'
    info = info .. "\n" .. kind .. ": " .. sig .. " "
  end
  
  local fpos, fline, path = M.ast_to_definition_position(ast, tokenlist)
  if fpos or fline then
    local fcol
    if fpos then
      fline, fcol = LA.pos_to_linecol(fpos, src)
    end
    local location = path .. ":" .. (fline) .. (fcol and ":" .. fcol or "")
    info = info .. "\nlocation defined: " .. location .. " "
  end
  
  -- Render warning notes attached to calls/invokes.
  local note = vast.parent and (vast.parent.tag == 'Call' or vast.parent.tag == 'Invoke')
                    and vast.parent.note
  if note then
    info = info .. "\nWARNING: " .. note .. " "
  end
  
  return info
end


-- Gets list of all warnings, as strings.
-- In HTML Tidy format (which supports column numbers in SciTE, although is
-- slightly verbose and lacks filename).
function M.list_warnings(tokenlist, src)
  local warnings = {}
  local ttoken
  local function warn(msg)
    local linenum, colnum = LA.pos_to_linecol(ttoken.fpos, src)
    warnings[#warnings+1] = "line " .. linenum .. " column " .. colnum .. " - " .. msg
  end
  local isseen = {}
  for i,token in ipairs(tokenlist) do ttoken = token
    if token.ast then
      local ast = token.ast
      if ast.localmasking then
        local pos = LA.ast_pos_range(ast.localmasking, tokenlist)
        local linenum = pos and LA.pos_to_linecol(pos, src)
        warn("local " .. ast[1] .. " masks another local" .. (pos and " on line " .. linenum or ""))
      end
      if ast.localdefinition == ast and not ast.isused then
        warn("unused local " .. ast[1])
      end
      if ast.isfield and not(known(ast.seevalue.value) and ast.seevalue.value ~= nil) then
        warn("unknown field " .. ast[1])
      elseif ast.tag == 'Id' and not ast.localdefinition and not ast.definedglobal then
        warn("unknown global " .. ast[1])
      end
      local vast = ast.seevalue or ast
      local note = vast.parent and (vast.parent.tag == 'Call' or vast.parent.tag == 'Invoke')
                    and vast.parent.note
      if note and not isseen[vast.parent] then
        isseen[vast.parent] = true
        local esrc = LA.ast_to_text(vast.parent, tokenlist, src)
           -- IMPROVE: large items like `f(function() ... end)` may be shortened.
        warn(note .. (esrc and "for " .. esrc or ""))
      end
    end
  end
  return warnings
end


return M
