command! Browse echo "Hello"

augroup fugue
  autocmd!
  autocmd BufReadCmd fugue://overlay call s:OpenFugueOverlay()
  autocmd WinResized * call s:UpdateFugueOverlay()
augroup END

let s:fugue_winid = -1
let s:macvim_bounds = v:null
let s:titlebar_height = v:null
let s:macvim_cell_pad_top = 1
let s:macvim_cell_pad_left = 2

let s:script_dir = fnamemodify(expand('<sfile>:p:h'), ':p')
let s:broz_path = substitute(fnamemodify(s:script_dir . '/../broz', ':p'), '/$', '', '')
let s:path_entries = map(split($PATH, ':'), 'substitute(v:val, "/$", "", "")')
if empty($PATH)
  let $PATH = s:broz_path
  "let @m= '[fugue] PATH empty, set to ' . s:broz_path
elseif index(s:path_entries, s:broz_path) < 0
  let $PATH = s:broz_path . ':' . $PATH
  "let @m='[fugue] prepended to PATH: ' . s:broz_path
else
  "let @m='[fugue] broz already in PATH'
endif

function! s:OpenFugueOverlay() abort
  echom strftime('%c')
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal modifiable nowrap nonumber norelativenumber
  call setline(1, 'Fugue overlay active...')
  setlocal nomodified
  let s:fugue_winid = win_getid()
  call s:GetMacVimBounds()
  call s:GetTitlebarHeight()
  call s:UpdateFugueOverlay()
endfunction

function! s:UpdateFugueOverlay() abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  let info = getwininfo(s:fugue_winid)
  if empty(info)
    return
  endif
  let w = info[0]
  let cell_px = getcellpixels()
  let payload = {
        \ 'winid': s:fugue_winid,
        \ 'topCell': w.winrow,
        \ 'leftCell': w.wincol,
        \ 'widthCells': w.width,
        \ 'heightCells': w.height,
        \ 'cellWidthPx': empty(cell_px) ? v:null : cell_px[0],
        \ 'cellHeightPx': empty(cell_px) ? v:null : cell_px[1],
        \ }
  let macvim = s:GetMacVimBounds()
  let titlebar = s:GetTitlebarHeight()
  if !empty(macvim) && !empty(cell_px)
    let payload.topPxWin = macvim.y + titlebar + s:macvim_cell_pad_top + (w.winrow - 1) * cell_px[1]
    let payload.leftPxWin = macvim.x + s:macvim_cell_pad_left + (w.wincol - 1) * cell_px[0]
    let payload.widthPx = w.width * cell_px[0]
    let payload.heightPx = w.height * cell_px[1]
    let payload.mvimTopPx = macvim.y + titlebar + s:macvim_cell_pad_top
    let payload.mvimLeftPx = macvim.x + s:macvim_cell_pad_left
    let payload.mvimWidthPx = macvim.width
    let payload.mvimHeightPx = macvim.height
    let payload.titlebarHeightPx = titlebar
    let payload.cellPadPx = {'top': s:macvim_cell_pad_top, 'left': s:macvim_cell_pad_left}
  endif

  let line = json_encode(payload)
  noautocmd call win_execute(s:fugue_winid, [
        \ 'setlocal modifiable',
        \ 'silent %delete _',
        \ 'call setline(1, ' . string(line) . ')',
        \ 'setlocal nomodified',
        \ ])
endfunction

function! s:GetMacVimBounds() abort
  if type(s:macvim_bounds) == type({}) && !empty(s:macvim_bounds)
    return copy(s:macvim_bounds)
  endif
  if !has('mac')
    let s:macvim_bounds = {}
    return {}
  endif
  let server = v:servername
  if empty(server)
    let s:macvim_bounds = {}
    return {}
  endif
  let script = [
        \ 'const serverName = ' . json_encode(server) . ';',
        \ 'const se = Application("System Events");',
        \ 'const mvim = se.processes.byName("MacVim");',
        \ 'if (!mvim.exists()) {',
        \ '  console.log("MacVim process not found");',
        \ '} else {',
        \ '  const wins = mvim.windows().filter(w => w.name().includes(serverName));',
        \ '  if (wins.length === 0) {',
        \ '    console.log("No window found for " + serverName);',
        \ '  } else {',
        \ '    const win = wins[0];',
        \ '    const [x, y] = win.position();',
        \ '    const [w, h] = win.size();',
        \ '    console.log(`{${x}, ${y}} {${w}, ${h}}`);',
        \ '  }',
        \ '}',
        \ ]
  let result = system('osascript -l JavaScript', join(script, "\n"))
  if v:shell_error != 0
    let s:macvim_bounds = {}
    return {}
  endif
  let match = matchlist(result, '{\s*\(\d\+\)\s*,\s*\(\d\+\)\s*}\s*{\s*\(\d\+\)\s*,\s*\(\d\+\)\s*}')
  if empty(match)
    let s:macvim_bounds = {}
    return {}
  endif
  let s:macvim_bounds = {
        \ 'x': str2nr(match[1]),
        \ 'y': str2nr(match[2]),
        \ 'width': str2nr(match[3]),
        \ 'height': str2nr(match[4]),
        \ }
  return copy(s:macvim_bounds)
endfunction

function! s:GetTitlebarHeight() abort
  if type(s:titlebar_height) == type(0) && s:titlebar_height >= 0
    return s:titlebar_height
  endif
  if !has('mac')
    let s:titlebar_height = 0
    return 0
  endif
  let server = v:servername
  if empty(server)
    let s:titlebar_height = 0
    return 0
  endif
  let script = [
        \ 'const serverName = ' . json_encode(server) . ';',
        \ 'const se = Application("System Events");',
        \ 'const mvim = se.processes.byName("MacVim");',
        \ 'if (!mvim.exists()) {',
        \ '  console.log(JSON.stringify({ error: "MacVim not found" }));',
        \ '  throw new Error("MacVim not found");',
        \ '}',
        \ 'const win = mvim.windows().find(w => w.name().includes(serverName));',
        \ 'if (!win) {',
        \ '  console.log(JSON.stringify({ error: "No window" }));',
        \ '  throw new Error("No window");',
        \ '}',
        \ 'const [wx, wy] = win.position();',
        \ 'const btn = win.buttons()[0];',
        \ 'if (!btn) {',
        \ '  console.log(JSON.stringify({ error: "No button" }));',
        \ '  throw new Error("No button");',
        \ '}',
        \ 'const btnPos = btn.position();',
        \ 'const btnSize = btn.size();',
        \ 'const by = btnPos.length > 1 ? btnPos[1] : wy;',
        \ 'const bh = btnSize.length > 1 ? btnSize[1] : 0;',
        \ 'const padding = by - wy;',
        \ 'const titlebarHeight = padding * 2 + bh;',
        \ 'console.log(JSON.stringify({ titlebarHeight }));',
        \ ]
  let result = system('osascript -l JavaScript', join(script, "\n"))
  if v:shell_error != 0
    let s:titlebar_height = 0
    return 0
  endif
  let trimmed = trim(result)
  if empty(trimmed)
    let s:titlebar_height = 0
    return 0
  endif
  try
    let data = json_decode(trimmed)
  catch
    let s:titlebar_height = 0
    return 0
  endtry
  if type(data) != type({}) || !has_key(data, 'titlebarHeight')
    let s:titlebar_height = 0
    return 0
  endif
  let s:titlebar_height = data.titlebarHeight
  return s:titlebar_height
endfunction
