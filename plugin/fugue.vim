command! Browse echo "Hello2"
command! -bang -nargs=? Fugue call s:OpenFugueCommand(<bang>0, <q-mods>, <q-args>)

augroup fugue
  autocmd!
  autocmd WinResized * call s:UpdateFugueOverlay()
  autocmd VimResized * call s:UpdateFugueOverlay()
  autocmd User WinNr call s:UpdateFugueOverlay()
  autocmd FocusLost * call s:OnFocusLost()
  autocmd FocusGained * call s:OnFocusGained()
  autocmd TabEnter * call s:OnTabEnter()
  autocmd TabClosed * call s:OnTabClosed()
  autocmd VimLeavePre * call s:StopBroz()
augroup END

let s:fugue_winid = -1
let s:titlebar_height = v:null
let s:macvim_cell_pad_top = 1
let s:macvim_cell_pad_left = 2
let s:broz_job = v:null
let s:broz_bufnr = -1
let s:last_payload = {}
let s:broz_url = 'https://pornhub.com'
let s:macvim_bounds = v:null
let s:state_timer = -1
let s:last_window_metrics = {}
let s:last_cell_pixels = []
let s:broz_hidden = 0
let s:fugue_tabnr = -1

let s:script_dir = fnamemodify(expand('<sfile>:p:h'), ':p')
let s:broz_path = substitute(fnamemodify(s:script_dir . '/../broz', ':p'), '/$', '', '')
if empty($PATH)
  let $PATH = s:broz_path
else
  let s:path_entries = map(split($PATH, ':'), 'substitute(v:val, "/$", "", "")')
  if index(s:path_entries, s:broz_path) < 0
    let $PATH = s:broz_path . ':' . $PATH
  endif
  unlet s:path_entries
endif

function! s:OpenFugueOverlay(...) abort
  if !has('terminal') || !exists('*term_start')
    call s:LogDebug('[fugue] :terminal not supported in this Vim build')
    call s:LogDebug('[fugue] missing keys in payload')
    return
  endif
  call s:StopBroz()
  let s:fugue_winid = win_getid()
  let s:broz_hidden = 0
  let s:fugue_tabnr = tabpagenr()
  call s:GetMacVimBounds()
  call s:GetTitlebarHeight()
  let payload = s:GatherGeometry()
  call s:LogDebug('[fugue] gather payload ' . json_encode(payload))
  let s:last_payload = payload
  let cmd = ['broz.js', '--top']
  if !empty(payload)
    call extend(cmd, ['--width', string(payload.widthPx), '--height', string(payload.heightPx), '--x', string(payload.leftPxWin), '--y', string(payload.topPxWin)])
  endif
  let url = (a:0 && type(a:1) == v:t_string) ? trim(a:1) : ''
  let target_url = empty(url) ? s:broz_url : url
  let s:broz_url = target_url
  call add(cmd, target_url)
  let opts = {
        \ 'curwin': 1,
        \ 'term_kill': 'term',
        \ 'term_name': 'Fugue Broz',
        \ 'exit_cb': function('s:OnBrozExit'),
        \ }
  let term_bufnr = term_start(cmd, opts)
  if term_bufnr <= 0
    call s:LogDebug('[fugue] failed to start broz.js')
    return
  endif
  let s:broz_bufnr = term_bufnr
  let g:broz_bufnr = term_bufnr
  let term_job = term_getjob(term_bufnr)
  if term_job is v:null || type(term_job) != v:t_job
    call s:LogDebug('[fugue] failed to obtain broz job handle')
    call s:StopBroz()
    return
  endif
  let s:broz_job = term_job
  call s:LogDebug('[fugue] broz job active buffer=' . s:broz_bufnr)
  if exists('*term_setapi')
    call term_setapi(s:broz_bufnr, 'FugueApi_')
  endif
  if exists('*timer_start')
    call timer_start(120, function('s:TriggerUpdate'))
    call s:StartStateWatcher()
  endif
endfunction

function! s:OpenFugueCommand(use_current, mods, url) abort
  let mods = type(a:mods) == v:t_string ? trim(a:mods) : ''
  let url = type(a:url) == v:t_string ? trim(a:url) : ''
  if !empty(url) && s:BrozIsActive()
    call s:SetBrozUrl(url)
    return
  endif
  if a:use_current
    if !empty(mods)
      call s:LogDebug('[fugue] ignoring modifiers for :Fugue! (current window)')
    endif
  else
    let split_cmd = empty(mods) ? 'vertical new' : mods . ' new'
    execute split_cmd
  endif
  if empty(url)
    call s:OpenFugueOverlay()
  else
    call s:OpenFugueOverlay(url)
  endif
endfunction

function! s:UpdateFugueOverlay() abort
  call s:TriggerUpdate(0)
endfunction

function! s:GatherGeometry() abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    call s:LogDebug('[fugue] invalid window id ' . s:fugue_winid)
    return {}
  endif
  let info = getwininfo(s:fugue_winid)
  if empty(info)
    call s:LogDebug('[fugue] getwininfo empty')
    return {}
  endif
  let w = info[0]
  let cell_px = getcellpixels()
  if empty(cell_px)
    call s:LogDebug('[fugue] getcellpixels empty')
    return {}
  endif
  let cell_w = s:ToInt(cell_px[0])
  let cell_h = s:ToInt(cell_px[1])
  if cell_w <= 0 || cell_h <= 0
    call s:LogDebug('[fugue] invalid cell size ' . string([cell_w, cell_h]))
    return {}
  endif
  let payload = {
        \ 'winid': s:fugue_winid,
        \ 'topCell': w.winrow,
        \ 'leftCell': w.wincol,
        \ 'widthCells': w.width,
        \ 'heightCells': w.height,
        \ 'cellWidthPx': cell_w,
        \ 'cellHeightPx': cell_h,
        \ }
  let payload.widthPx = s:ToInt(w.width * cell_w)
  let payload.heightPx = s:ToInt(w.height * cell_h)
  let macvim = s:GetMacVimBounds()
  let titlebar = s:GetTitlebarHeight()
  if !empty(macvim)
    let payload.mvimTopPx = s:ToInt(macvim.y + titlebar + s:macvim_cell_pad_top)
    let payload.mvimLeftPx = s:ToInt(macvim.x + s:macvim_cell_pad_left)
    let payload.mvimWidthPx = s:ToInt(macvim.width)
    let payload.mvimHeightPx = s:ToInt(macvim.height)
    let payload.titlebarHeightPx = s:ToInt(titlebar)
    let payload.cellPadPx = {'top': s:macvim_cell_pad_top, 'left': s:macvim_cell_pad_left}
    let payload.topPxWin = s:ToInt(macvim.y + titlebar + s:macvim_cell_pad_top + (w.winrow - 1) * cell_h)
    let payload.leftPxWin = s:ToInt(macvim.x + s:macvim_cell_pad_left + (w.wincol - 1) * cell_w)
  endif
  return payload
endfunction

function! s:SendToBroz(payload) abort
  if !has('channel')
    call s:LogDebug('[fugue] channels not supported in this Vim build')
    return
  endif
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    call s:LogDebug('[fugue] missing broz job handle')
    return
  endif
  try
    if job_status(s:broz_job) !=# 'run'
      return
    endif
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    call s:LogDebug('[fugue] job_status failed, clearing job handle')
    let s:broz_job = v:null
    return
  endtry
  if s:broz_bufnr == -1 || !bufexists(s:broz_bufnr)
    call s:LogDebug('[fugue] terminal buffer missing')
    return
  endif
  let term_channel = job_getchannel(s:broz_job)
  if term_channel is v:null || type(term_channel) != v:t_channel
    call s:LogDebug('[fugue] failed to obtain terminal channel')
    return
  endif
  let request = {}
  if has_key(a:payload, 'action')
    let request.action = a:payload.action
  endif
  if has_key(a:payload, 'widthPx') && has_key(a:payload, 'heightPx')
        \ && has_key(a:payload, 'topPxWin') && has_key(a:payload, 'leftPxWin')
    let request.width = s:ToInt(a:payload.widthPx)
    let request.height = s:ToInt(a:payload.heightPx)
    let request.x = s:ToInt(a:payload.leftPxWin)
    let request.y = s:ToInt(a:payload.topPxWin)
  endif
  if !has_key(request, 'action') && !has_key(request, 'width')
    return
  endif
  let message = json_encode(request) . "\n"
  call s:LogDebug('[fugue] send ' . message)
  call ch_sendraw(term_channel, message)
endfunction

function! s:BrozIsActive() abort
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return 0
  endif
  try
    return job_status(s:broz_job) ==# 'run'
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    return 0
  endtry
endfunction

function! s:SetBrozUrl(url) abort
  if empty(a:url) || !has('channel')
    return
  endif
  if !s:BrozIsActive()
    return
  endif
  let channel = job_getchannel(s:broz_job)
  if channel is v:null || type(channel) != v:t_channel
    return
  endif
  let s:broz_url = a:url
  let message = json_encode({'url': a:url}) . "\n"
  call s:LogDebug('[fugue] send url ' . a:url)
  call ch_sendraw(channel, message)
  call s:TriggerUpdate(0)
endfunction

function! s:HideBrozOverlay() abort
  if s:broz_hidden || !s:BrozIsActive()
    return
  endif
  call s:SendToBroz({'action': 'hide'})
  let s:broz_hidden = 1
endfunction

function! s:ShowBrozOverlay() abort
  if !s:BrozIsActive()
    return
  endif
  let payload = empty(s:last_payload) ? s:GatherGeometry() : copy(s:last_payload)
  if empty(payload)
    return
  endif
  let s:last_payload = copy(payload)
  let payload.action = 'show'
  call s:SendToBroz(payload)
  let s:broz_hidden = 0
endfunction

function! s:OnFocusLost() abort
  call s:HideBrozOverlay()
endfunction

function! s:OnFocusGained() abort
  if s:broz_hidden
    call s:ShowBrozOverlay()
  else
    call s:TriggerUpdate(0)
  endif
endfunction

function! s:GetFugueTabnr() abort
  if s:fugue_winid == -1
    return -1
  endif
  if exists('*win_id2tabwin')
    let tabinfo = win_id2tabwin(s:fugue_winid)
    if type(tabinfo) == v:t_list && len(tabinfo) >= 1 && tabinfo[0] > 0
      return tabinfo[0]
    endif
  endif
  for tabdata in gettabinfo()
    if has_key(tabdata, 'windows') && index(tabdata.windows, s:fugue_winid) >= 0
      return tabdata.tabnr
    endif
  endfor
  return -1
endfunction

function! s:OnTabEnter() abort
  if !s:BrozIsActive()
    return
  endif
  let fugue_tab = s:GetFugueTabnr()
  let s:fugue_tabnr = fugue_tab
  if fugue_tab == -1
    call s:HideBrozOverlay()
    return
  endif
  if tabpagenr() == fugue_tab
    call s:ShowBrozOverlay()
  else
    call s:HideBrozOverlay()
  endif
endfunction

function! s:OnTabClosed() abort
  if !exists('v:oldtabpage')
    return
  endif
  if v:oldtabpage == s:fugue_tabnr
    call s:HideBrozOverlay()
    let s:fugue_tabnr = -1
    if s:fugue_winid != -1 && win_id2win(s:fugue_winid) == 0
      let s:fugue_winid = -1
    endif
  endif
endfunction

function! FugueApi_FocusOverlayWindow(bufnr, args) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  let @w=s:fugue_winid
  let @v=bufnr()
  "call win_execute(s:fugue_winid, 'call feedkeys("\<C-w>:", "ntx")')
endfunction

function! s:StopBroz() abort
  call s:StopStateWatcher()
  if type(s:broz_job) == v:t_job
    try
      if job_status(s:broz_job) ==# 'run'
        call job_stop(s:broz_job, 'term')
      endif
    catch /^Vim\%((\a\+)\)\=:E\d\+/
      " Ignore invalid job handle when stopping
    endtry
  endif
  let s:broz_job = v:null
  let s:broz_bufnr = -1
  let s:fugue_winid = -1
  let s:last_payload = {}
  let s:last_window_metrics = {}
  let s:last_cell_pixels = []
  let s:broz_hidden = 0
  let s:fugue_tabnr = -1
endfunction

function! s:TriggerUpdate(timer) abort
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return
  endif
  try
    if job_status(s:broz_job) !=# 'run'
      return
    endif
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    let s:broz_job = v:null
    return
  endtry
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  let payload = s:GatherGeometry()
  if empty(payload)
    call s:LogDebug('[fugue] payload empty, retry later')
    if exists('*timer_start')
      call timer_start(120, function('s:TriggerUpdate'))
    endif
    return
  endif
  if s:broz_hidden
    let s:last_payload = copy(payload)
    return
  endif
  if !empty(s:last_payload) && s:PayloadEquals(s:last_payload, payload)
    return
  endif
  let s:last_payload = copy(payload)
  call s:LogDebug('[fugue] updating broz with ' . json_encode(payload))
  call s:SendToBroz(payload)
endfunction

function! s:OnBrozExit(job, status) abort
  let s:broz_job = v:null
  let s:broz_bufnr = -1
  let s:fugue_winid = -1
endfunction


function! s:LogDebug(msg) abort
  let lines = getreg('d', 1, 1)
  call add(lines, a:msg)
  call setreg('d', lines)
endfunction
function! s:GetMacVimBounds() abort
  if type(s:macvim_bounds) == v:t_dict && !empty(s:macvim_bounds)
    return s:macvim_bounds
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
  return s:macvim_bounds
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
  let s:titlebar_height = s:ToInt(data.titlebarHeight)
  return s:titlebar_height
endfunction

function! s:ToInt(value) abort
  if type(a:value) == type(0.0)
    return float2nr(a:value)
  endif
  return a:value
endfunction

function! s:StartStateWatcher() abort
  if !exists('*timer_start')
    return
  endif
  if s:state_timer != -1
    call timer_stop(s:state_timer)
  endif
  let s:last_window_metrics = {}
  let s:last_cell_pixels = getcellpixels()
  let s:state_timer = timer_start(200, function('s:PollWindowState'), {'repeat': -1})
endfunction

function! s:StopStateWatcher() abort
  if s:state_timer != -1
    call timer_stop(s:state_timer)
    let s:state_timer = -1
  endif
endfunction

function! s:PollWindowState(timer) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return
  endif
  let info = getwininfo(s:fugue_winid)
  if empty(info)
    return
  endif
  let w = info[0]
  let current_metrics = {
        \ 'row': w.winrow,
        \ 'col': w.wincol,
        \ 'width': w.width,
        \ 'height': w.height,
        \ }
  let needs_update = 0
  if empty(s:last_window_metrics) || s:last_window_metrics !=# current_metrics
    let s:last_window_metrics = current_metrics
    let needs_update = 1
  endif
  let pixels = getcellpixels()
  if type(pixels) == v:t_list
    if empty(s:last_cell_pixels) || s:last_cell_pixels !=# pixels
      let s:last_cell_pixels = pixels
      let needs_update = 1
    endif
  endif
  if needs_update
    call s:TriggerUpdate(0)
  endif
endfunction

function! s:PayloadEquals(left, right) abort
  let keys = ['widthPx', 'heightPx', 'topPxWin', 'leftPxWin']
  for key in keys
    if get(a:left, key, v:null) !=# get(a:right, key, v:null)
      return 0
    endif
  endfor
  return 1
endfunction

if has('mac') && !empty(v:servername)
  call s:GetMacVimBounds()
endif
function! FugueApi_SendKeys(bufnr, args) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  if type(a:args) != v:t_list || empty(a:args)
    return
  endif
  call win_gotoid(s:fugue_winid)
  for key in a:args
    if type(key) != v:t_string || empty(key)
      continue
    endif
    call feedkeys(key, 'n')
  endfor
endfunction
