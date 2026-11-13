local out={}
local function walk(t,p,d)
 if d>4 then return end
 for k,v in pairs(t) do local name=p..tostring(k); out[#out+1]=name..':'..type(v); if type(v)=='table' then walk(v,name..'.',d+1) end end
end
walk(_ENV,'',0); table.sort(out); return out
