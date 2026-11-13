xpcall(function() local s='xx'; for i=1,40 do s=s..s end; return s end,function(e) return e end); return helper_echo('continued')
