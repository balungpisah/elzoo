local t={a=1,z=2,[2]=3,[7]=4,[false]=5}
local p={}; for k,v in pairs(t) do p[#p+1]=tostring(k)..'='..v end
local n={}; local k=nil; repeat k=next(t,k); if k~=nil then n[#n+1]=tostring(k) end until k==nil
local errors={}; for _,f in ipairs({function() return 1+{} end,function() return ('x'):sub({}) end,function() error('fixed') end}) do
 local ok,e=pcall(f); errors[#errors+1]=e end
return {pairs=table.concat(p,','),next=table.concat(n,','),object=tostring({}),func=tostring(function() end),
errors=errors,holes=#{[1]=1,[3]=3,[8]=8},numbers={tostring(1e15),tostring(2^53),tostring(1/3),tostring(3//0.0),tostring(3/2),tostring(7//2),tostring(math.maxinteger+1)},
format=string.format('%.17g',1/3),gsub=string.gsub('a12b34','%d+','X'),find={string.find('a12b','(%d+)')}}
