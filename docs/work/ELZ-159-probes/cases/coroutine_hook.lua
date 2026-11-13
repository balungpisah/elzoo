local co=coroutine.create(function() while true do end end); coroutine.resume(co); return 'continued'
