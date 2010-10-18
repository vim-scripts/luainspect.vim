--[[

 This module is part of the luainspect.vim plug-in for the Vim text editor.

 Author: Peter Odding <peter@peterodding.com>
 Last Change: August 10, 2010
 URL: http://peterodding.com/code/vim/lua-inspect/
 License: MIT

--]]

local myprint
if type(vim) == 'table' and vim.eval then
  -- The Lua interface for Vim redefines print() so it prints inside Vim.
  myprint = print
else
  -- My $LUA_INIT script redefines print() to enable pretty printing in the
  -- interactive prompt, which means strings are printed with surrounding
  -- quotes. This would break the communication between Vim and this script.
  function myprint(text) io.write(text, '\n') end
end

local function getcurvar(tokenlist, line, column)
  for i, token in ipairs(tokenlist) do
    if token.ast.lineinfo then
      local l1, c1 = unpack(token.ast.lineinfo.first, 1, 2)
      local l2, c2 = unpack(token.ast.lineinfo.last, 1, 2)
      if l1 == line and column >= c1 and column <= c2 then
        if token.ast.id then return token end
      end
    end
  end
end

return function(src)
  local LI = require 'luainspect.init'
  local LA = require 'luainspect.ast'
  local line, column, src = src:match '^(%d+)\n(%d+)\n(.*)$'
  line = tonumber(line)
  column = tonumber(column)
  src = LA.remove_shebang(src)
  local f, err, linenum, colnum, linenum2 = LA.loadstring(src)
  if not f then
    if not linenum2 then
      myprint(linenum)
    else
      myprint(linenum2 .. ' ' .. linenum)
    end
    return
  end
  local ast; ast, err, linenum, colnum, linenum2 = LA.ast_from_string(src, "noname.lua")
  if not ast then return end
  local tokenlist = LA.ast_to_tokenlist(ast, src)
  LI.inspect(ast, tokenlist)
  local curvar = getcurvar(tokenlist, line, column)
  for i, token in ipairs(tokenlist) do
    local kind
    if curvar and curvar.ast.id == token.ast.id then
      kind = 'luaInspectSelectedVariable'
    elseif token.tag == 'Id' then
      if not token.ast.localdefinition then
        if token.ast.definedglobal then
          kind = 'luaInspectGlobalDefined'
        else
          kind = 'luaInspectGlobalUndefined'
        end
      elseif not token.ast.localdefinition.isused then
        kind = 'luaInspectLocalUnused'
      elseif token.ast.localdefinition.functionlevel < token.ast.functionlevel then
        kind = 'luaInspectUpValue'
      elseif token.ast.localdefinition.isset then
        kind = 'luaInspectLocalMutated'
      elseif token.ast.localdefinition.isparam then
        kind = 'luaInspectParam'
      else
        kind = 'luaInspectLocal'
      end
    elseif token.ast.isfield then
      if token.ast.definedglobal or token.ast.seevalue.valueknown and token.ast.seevalue.value ~= nil then
        kind = 'luaInspectFieldDefined'
      else
        kind = 'luaInspectFieldUndefined'
      end
    end
    if kind then
      local l1, c1 = unpack(token.ast.lineinfo.first, 1, 2)
      local l2, c2 = unpack(token.ast.lineinfo.last, 1, 2)
      if l1 == l2 then
        myprint(kind .. ' ' .. l1 .. ' ' .. c1 .. ' ' .. c2)
      end
    end
  end
end

-- Enable type checking of ast.* expressions.
--! require 'luainspect.typecheck' (context)

-- vim: ts=2 sw=2 et
