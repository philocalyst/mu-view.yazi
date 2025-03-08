local M = {}

-- Constants
local PREVIEW = {
	tab_size = 4
}

-- Check if mu is installed
local function is_mu_installed()
	local status, err = Command("which")
			:args({ "mu" })
			:stdin(Command.NULL)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
			:wait()
		:status()

	return status.success
end

-- Check if lynx is installed
local function is_lynx_installed()
	local status, err = Command("which")
			:args({ "lynx" })
			:stdin(Command.NULL)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
			:wait()
			:status()

	return status.success
end

local function dependencies_installed()
	if is_lynx_installed and is_mu_installed then
		return true
	else
		return false
	end
end

-- Helper functions for consistent logging
local function log_debug(message)
	ya.dbg("[mu-viewer] " .. message)
end

local function log_error(message)
	ya.err("[mu-viewer] ERROR: " .. message)
end

-- Parse mail content with mu view using specified format
local function parse_mail_content(file_url, format)
	log_debug("Parsing mail with format: " .. format)
	return Command("mu")
			:args({
				"view",
				"--format",
				format,
				"--nocolor=false",
				tostring(file_url),
			})
			:stdin(Command.NULL)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
end

-- Process HTML content through lynx for better rendering
local function process_html_with_lynx(html_content, width)
	log_debug("Processing HTML content with lynx, width: " .. width)
	local lynx = Command("lynx")
			:args({
				"-dump",
				"-stdin",
				"-nomargins",
				"-width=" .. width,
				"-display_charset=utf-8", -- Force UTF-8 output
				"-force_html",        -- Force HTML interpretation
				"-nobrowse"           -- Don't start interactive browser
			})
			:stdin(Command.PIPED)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()

	-- Begin writing the HTML content to lynx's stdin
	local write_ok, write_err = lynx:write_all(html_content)
	if not write_ok then
		log_error("Failed to write HTML to lynx: " .. tostring(write_err))
		return nil, write_err
	end

	-- Flush to ensure all data is sent
	local flush_ok, flush_err = lynx:flush()
	if not flush_ok then
		log_error("Failed to flush data to lynx: " .. tostring(flush_err))
	end

	-- Get lynx output
	local output, err = lynx:wait_with_output()
	if not output then
		log_error("Failed to get lynx output: " .. tostring(err))
		return nil, err
	end

	return output.stdout, nil
end

-- Collect all content from command output instead of line by line
local function collect_full_output(child)
	local stdout_content = ""
	local stderr_content = ""

	-- Read all content
	while true do
		local next, event = child:read_line()

		if event == 0 then
			-- This is stdout
			stdout_content = stdout_content .. (next or "")
		elseif event == 1 then
			-- This is stderr
			stderr_content = stderr_content .. (next or "")
			if next and next ~= "" then
				log_error("STDERR: " .. next)
			end
		else
			-- End of stream or error
			break
		end
	end

	return stdout_content, stderr_content
end

function isolate_headers(input)
	local headers = {}
	local html = {}

	-- Split the input string into lines
	local lines = {}
	for line in input:gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	-- Find the boundary between headers and HTML content
	-- Headers usually end with an empty line before the HTML content
	local is_html = false
	for i, line in ipairs(lines) do
		if is_html then
			table.insert(html, line)
		else
			-- Check for empty line signaling the end of headers
			if line == "" then
				is_html = true
			else
				table.insert(headers, line)
			end
		end
	end

	return headers, table.concat(html, "\n")
end

function M:peek(job)
	if not dependencies_installed() then
		ya.notify {
			title = "Mu-View: Missing Dependencies",
			content = "Ensure both lynx and mu are on your $PATH",
			timeout = 5,
			-- level = "Error",
		}
	end

	log_debug("Starting peek for: " .. tostring(job.file.url))

	local content = nil
	local success = false

	-- Try with plain format first, then fallback to HTML as last resort
	for _, current_format in ipairs({ "0", "2" }) do
		if success then break end

		log_debug("Trying format: " .. current_format)
		local child = parse_mail_content(job.file.url, current_format)
		if not child then
			log_error("Failed to create mu view command")
			break
		end

		-- Get the complete command for logging
		local cmd_str = "mu view --format " .. current_format .. " --nocolor=false " .. tostring(job.file.url)
		log_debug("Executing: " .. cmd_str)

		-- Collect all output instead of paginating
		local full_output, stderr = collect_full_output(child)

		-- Clean up the process
		child:start_kill()

		-- Check if we got "[No plain text body found]" message
		if full_output:find("%[No plain text body found%]") and current_format == "0" then
			log_debug("No plain text body found, will try HTML format")
		else
			-- Process HTML if needed
			if current_format == "2" then
				log_debug("Processing HTML content (length: " .. #full_output .. " bytes)")
				local headers, html_content = isolate_headers(full_output)
				local html_output, html_err = process_html_with_lynx(html_content, job.area.w)
				if not html_output then
					log_error("HTML processing failed: " .. tostring(html_err))
					-- Continue with raw HTML as fallback
					content = full_output
				else
					-- Join headers with processed HTML content
					content = table.concat(headers, "\n") .. "\n\n" .. html_output
				end
			else
				content = full_output
			end

			success = true
			break
		end
	end

	if not success or not content then
		log_error("Failed to render email content")
		ya.preview_widgets(job, {
			ui.Text.parse("ERROR: Failed to render email content"):area(job.area)
		})
		return
	end

	-- Format content
	content = content:gsub("\t", string.rep(" ", PREVIEW.tab_size))
	log_debug("Rendering " .. #content .. " bytes of content")

	-- Handle pagination
	local lines = {}
	for line in content:gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	local start_line = job.skip + 1
	local end_line = math.min(start_line + job.area.h - 1, #lines)
	local displayed_content = table.concat(lines, "\n", start_line, end_line)

	-- Display output
	ya.preview_widgets(job, { ui.Text.parse(displayed_content):area(job.area) })

	-- Handle scroll boundary conditions
	if job.skip > 0 and end_line < #lines and end_line - start_line + 1 < job.area.h then
		log_debug("Reached boundary, adjusting scroll position")
		ya.mgr_emit("peek", {
			math.max(0, #lines - job.area.h),
			only_if = job.file.url,
			upper_bound = true
		})
	end
end

function M:seek(job)
	log_debug("Seeking: " .. tostring(job.units) .. " units for " .. tostring(job.file.url))
	-- Call peek with updated skip value
	local units = math.max(0, job.skip + job.units)
	require("code").seek(job, units)
end

return M
