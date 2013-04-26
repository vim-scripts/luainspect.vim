# Semantic highlighting for Lua in Vim

The Vim plug-in `luainspect.vim` uses the [LuaInspect](http://lua-users.org/wiki/LuaInspect) tool to (automatically) perform semantic highlighting of variables in Lua source code. It was inspired by [lua2-mode](http://www.enyo.de/fw/software/lua-emacs/lua2-mode.html) (for [Emacs](http://www.gnu.org/software/emacs/)) and the [SciTE](http://www.scintilla.org/SciTE.html) plug-in included with LuaInspect. In addition to the semantic highlighting the following features are currently supported:

 * Press `<F2>` with the text cursor on a variable and the plug-in will prompt you to rename the variable.

 * Press `gd` (in normal mode) with the text cursor on a variable and you'll jump to its declaration / first occurrence.

 * When you hover over a variable with the mouse cursor in graphical Vim, information about the variable is displayed in a tooltip.

 * If the text cursor is on a variable while the highlighting is refreshed then all occurrences of the variable will be marked in the style of [Vim's cursorline option](http://vimdoc.sourceforge.net/htmldoc/options.html#%27cursorline%27).

 * When luainspect reports a wrong argument count for a function call the text will be highlighted with a green underline. When you hover over the highlighted text a tooltip shows the associated warning message.

 * When LuaInspect reports warnings about unused variables, wrong argument counts, etc. they are shown in a [location list window](http://vimdoc.sourceforge.net/htmldoc/quickfix.html#location-list).

 * When a syntax error is found (during highlighting or using the rename functionality) the lines where the error is reported will be marked like a spelling error.

![Screenshot of semantic highlighting](http://peterodding.com/code/vim/luainspect/screenshot.png)

## Installation

Unzip the most recent [ZIP archive](http://peterodding.com/code/vim/downloads/lua-inspect.zip) file inside your Vim profile directory (usually this is `~/.vim` on UNIX and `%USERPROFILE%\vimfiles` on Windows), restart Vim and execute the command `:helptags ~/.vim/doc` (use `:helptags ~\vimfiles\doc` instead on Windows). Now try it out: Edit a Lua file and within a few seconds semantic highlighting should be enabled automatically!

Note that on Windows a command prompt window pops up whenever LuaInspect is run as an external process. If this bothers you then you can install my [shell.vim](http://peterodding.com/code/vim/shell/) plug-in which includes a [DLL](http://en.wikipedia.org/wiki/Dynamic-link_library) that works around this issue. Once you've installed both plug-ins it should work out of the box!

## Usage

When you open any Lua file the semantic highlighting should be enabled automatically within a few seconds, so you don't have to configure anything if you're happy with the defaults.

### The `:LuaInspect` command

You don't need to use this command unless you've disabled automatic highlighting using `g:lua_inspect_events`. When you execute this command the plug-in runs the LuaInspect tool and then highlights all variables in the current buffer using one of the following highlighting groups:

 * <span style="color: #600000">luaInspectGlobalDefined</span>
 * <span style="color: #FFF; background: #F00">luaInspectGlobalUndefined</span>
 * <span style="color: #FFF; background: #00F">luaInspectLocalUnused</span>
 * <span style="color: #000080; font-style: italic">luaInspectLocalMutated</span>
 * <span style="color: #00F">luaInspectUpValue</span>
 * <span style="color: #000040">luaInspectParam</span>
 * <span style="color: #000080">luaInspectLocal</span>
 * <span style="color: #600000">luaInspectFieldDefined</span>
 * <span style="color: #C00000">luaInspectFieldUndefined</span>
 * <span style="background: #D3D3D3">luaInspectSelectedVariable</span>
 * <span style="border-bottom: 1px dotted green">luaInspectWrongArgCount</span>
 * <span style="border-bottom: 1px dotted red">luaInspectSyntaxError</span>

If you don't like one or more of the default styles the Vim documentation [describes how to change them](http://vimdoc.sourceforge.net/htmldoc/syntax.html#:hi-default). If you want to disable the semantic highlighting in a specific Vim buffer execute `:LuaInspect!` in that buffer. When you want to re-enable the highlighting execute `:LuaInspect` again, but now without the [bang](http://vimdoc.sourceforge.net/htmldoc/map.html#:command-bang).

### The `:LuaInspectToggle` command

By default the semantic highlighting and the warning messages in the location list window are automatically applied to Lua buffers and updated every once in a while, but this can be disabled by setting `g:lua_inspect_events` to an empty string in your [vimrc script] [vimrc]. If the plug-in is not automatically enabled then it may be useful to enable/disable it using a key mapping. That's what the `:LuaInspectToggle` command is for. You still have to define your key mapping of choice in your [vimrc script] [vimrc] though. For example:

    " Don't enable the lua-inspect plug-in automatically in Lua buffers.
    let g:lua_inspect_events = ''

    " Enable/disable the lua-inspect plug-in manually using <F6>.
    imap <F6> <C-o>:LuaInspectToggle<CR>
    nmap <F6>      :LuaInspectToggle<CR>

### The `g:loaded_luainspect` option

This variable isn't really an option but if you want to avoid loading the `luainspect.vim` plug-in you can set this variable to any value in your [vimrc script](http://vimdoc.sourceforge.net/htmldoc/starting.html#vimrc):

    :let g:loaded_luainspect = 1

### The `g:lua_inspect_warnings` option

When LuaInspect reports warnings about unused variables, wrong argument counts, etc. they are automatically shown in a [location list window](http://vimdoc.sourceforge.net/htmldoc/quickfix.html#location-list). If you don't like this add the following to your [vimrc script](http://vimdoc.sourceforge.net/htmldoc/starting.html#vimrc):

    :let g:lua_inspect_warnings = 0

### The `g:lua_inspect_events` option

By default semantic highlighting is automatically enabled after a short timeout and when you save a buffer. If you want to disable automatic highlighting altogether add the following to your [vimrc script](http://vimdoc.sourceforge.net/htmldoc/starting.html#vimrc):

    :let g:lua_inspect_events = ''

You can also add events, for example if you also want to run `:LuaInspect` the moment you edit a Lua file then try this:

    :let g:lua_inspect_events = 'CursorHold,CursorHoldI,BufReadPost,BufWritePost'

Note that this only works when the plug-in is loaded (or reloaded) *after* setting the `g:lua_inspect_events` option.

### The `g:lua_inspect_internal` option

The plug-in uses the Lua interface for Vim when available so that it doesn't have to run LuaInspect as an external program (which can slow things down). If you insist on running LuaInspect as an external program you can set this variable to false (0) in your [vimrc script](http://vimdoc.sourceforge.net/htmldoc/starting.html#vimrc):

    :let g:lua_inspect_internal = 0

## Contact

If you have questions, bug reports, suggestions, etc. the author can be contacted at <peter@peterodding.com>. The latest version is available at <http://peterodding.com/code/vim/lua-inspect/> and <http://github.com/xolox/vim-lua-inspect>. If you like this plug-in please vote for it on [Vim Online](http://www.vim.org/scripts/script.php?script_id=3169).

## License

This software is licensed under the [MIT license](http://en.wikipedia.org/wiki/MIT_License).  
© 2013 Peter Odding &lt;<peter@peterodding.com>&gt;.


[vimrc]: http://vimdoc.sourceforge.net/htmldoc/starting.html#vimrc
