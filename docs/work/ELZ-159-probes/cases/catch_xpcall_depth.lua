xpcall(function() local function f(n) return 1+f(n+1) end; return f(0) end,function(e) return e end); return helper_echo('continued')
