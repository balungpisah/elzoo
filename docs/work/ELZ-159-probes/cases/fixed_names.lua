local out={}
for _,name in ipairs({'assert','collectgarbage','coroutine','debug','dofile','error','getmetatable','io','ipairs','load','loadfile','loadstring','math','next','os','package','pairs','pcall','print','rawequal','rawget','rawlen','rawset','require','select','setmetatable','string','table','tonumber','tostring','type','utf8','warn','xpcall','_G','_VERSION'}) do
 local ok,v=pcall(function() return _ENV[name] end); out[#out+1]=name..':'..(ok and type(v) or v)
end
for _,name in ipairs({'byte','char','dump','find','format','gmatch','gsub','len','lower','match','pack','packsize','rep','reverse','sub','unpack','upper','random','randomseed'}) do
 out[#out+1]='string-method.'..name..':'..type(('')[name])
end
return out
