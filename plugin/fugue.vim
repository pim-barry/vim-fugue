command! Browse echo "Hello"

augroup fugue
  autocmd!
  autocmd BufReadCmd fugue://overlay call s:OpenFugueOverlay()
  autocmd WinResized * call s:UpdateFugueOverlay()
augroup END

let s:fugue_winid = -1

function! s:OpenFugueOverlay() abort
  echom strftime('%c')
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal modifiable nowrap nonumber norelativenumber
  call setline(1, 'Fugue overlay active...')
  setlocal nomodified
  let s:fugue_winid = win_getid()
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
  let line = printf('winid=%d top=%d left=%d size=%dx%d',
        \ s:fugue_winid, w.winrow, w.wincol, w.width, w.height)
  noautocmd call win_execute(s:fugue_winid, [
        \ 'setlocal modifiable',
        \ 'silent %delete _',
        \ 'call setline(1, ' . string(line) . ')',
        \ 'setlocal nomodified',
        \ ])
endfunction
