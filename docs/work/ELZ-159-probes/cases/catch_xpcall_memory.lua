xpcall(function() local t={}; for i=1,100000000 do t[i]=string.rep('x'..i,1000) end; return t end,function(e) return e end); return helper_echo('continued')
