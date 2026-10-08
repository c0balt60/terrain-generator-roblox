local stdio = require("@lune/stdio")

local rstclr = stdio.color("reset")
local redclr = stdio.color("red")
local ylwclr = stdio.color("yellow")
local bluclr = stdio.color("blue")
local grnclr = stdio.color("green")

local function write(msg: string, color: string, err: boolean): ()
	local out_str: string = color .. msg .. rstclr .. "\n"
	if err then
		stdio.ewrite(out_str)
	else
		stdio.write(out_str)
	end
end

return {
	error = function(msg: string): ()
		write(msg, redclr, true)
	end,
	warn = function(msg: string): ()
		write(msg, ylwclr, false)
	end,
	info = function(msg: string): ()
		write(msg, bluclr, false)
	end,
	success = function(msg: string): ()
		write(msg, grnclr, false)
	end,
}
