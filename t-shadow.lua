modules = modules or { }
modules["t-shadow"] = {
    version = "2026.05.01",
    comment = "Shadow Module",
    author = "Aditya Mahajan",
    copyright = "Aditya Mahajan",
    license = "GNU General Public License",
}

thirddata = thirddata or { }
thirddata.externalshadow = { }
local externalshadow = thirddata.externalshadow

local format, gsub, todimen  = string.format, string.gsub, string.todimen
local floor, round, min, max = math.floor, math.round, math.min, math.max
local cosd, sind             = math.cosd, math.sind
local isfile, isdir, mkdirs  = lfs.isfile, lfs.isdir, lfs.mkdirs
local collapsepath           = file.collapsepath
local insert                 = table.insert

local getmacro        = tokens.getters.macro
local variables       = interfaces.variables
local getparameterset = metapost.getparameterset

local v_middle <const> = variables.middle
local v_round  <const> = variables.round
local v_color  <const> = variables.color
local v_yes    <const> = variables.yes
local v_off    <const> = variables.off

local report = logs.reporter("shadow")

local function shell_quote(p)
    return "'" .. gsub(p, "'", "'\\''") .. "'"
end

local function dimen_to_px(n, resolution)
    if n == nil or n == "" then return 0 end
    
    -- Metapost dimensions are passed as numbers.
    if type(n) == "number" then n = format("%fbp", n) end

    local pxdimen = tex.sp("1in") / resolution
    return round(tex.sp(todimen(n)) / pxdimen)
end

local model_to_colorspace = { rgb = "srgb", gray = "gray", cmyk = "cmyk" }

local function color_to_im(name, alpha)
    local t = attributes.colors.spec(name)
    if not t then return tostring(name), "srgb" end
    local model = t.model
    local function bpp(n) return round((n or 0) * 255) end
    if alpha < 1 then
        if model == "gray" then
            return format("graya(%s,%s)", bpp(t.s), bpp(alpha)), model_to_colorspace[model]
        elseif model == "rgb" then
            return format("rgba(%s,%s,%s,%s)", bpp(t.r), bpp(t.g), bpp(t.b), bpp(alpha)), model_to_colorspace[model]
        elseif model == "cmyk" then
            return format("cmyka(%s,%s,%s,%s,%s)", bpp(t.c), bpp(t.m), bpp(t.y), bpp(t.k), bpp(alpha)), model_to_colorspace[model]
        end
    else
        if model == "gray" then
            return format("gray(%s)", bpp(t.s)), model_to_colorspace[model]
        elseif model == "rgb" then
            return format("rgb(%s,%s,%s)", bpp(t.r), bpp(t.g), bpp(t.b)), model_to_colorspace[model]
        elseif model == "cmyk" then
            return format("cmyk(%s,%s,%s,%s)", bpp(t.c), bpp(t.m), bpp(t.y), bpp(t.k)), model_to_colorspace[model]
        end
    end
    return "gray(0)", "gray"
end

local function placement_sp(direction, offset)
    local d = tonumber(direction) or 270
    local o = tex.sp(todimen(offset) or 0)
    return round(cosd(d) * o), round(-sind(d) * o)
end

local function rectangle(w, h, rpx, corner, dx, dy)
    local x, y = max(1, w), max(1, h)
    local x1, y1 = 1 + dx, 1 + dy
    local x2, y2 = x + dx, y + dy
    if corner == v_round and rpx > 0 then
        return format("roundrectangle %d,%d %d,%d %d,%d", x1, y1, x2, y2, rpx, rpx)
    end
    return format("rectangle %d,%d %d,%d", x1, y1, x2, y2)
end

-- Build the two ImageMagick masks for the box shadow.
local function box_masks(spec)
    local w, h   = spec.width, spec.height
    local ud, pd = spec.udistance, spec.pdistance
    local rpx    = spec.backgroundradius
    local corner = spec.backgroundcorner

    local spread_pad = max(ud + 2 * spec.usigma, pd + 2 * spec.psigma) + 1
    local pad        = max(ud, pd) + 1

    local shift  = spread_pad - pad
    local width  = w + 2 * spread_pad
    local height = h + 2 * spread_pad

    local r_pen = min(rpx, floor(min(w + 2*pd, h + 2*pd) / 2))
    local r_umb = min(rpx, floor(min(w + 2*ud, h + 2*ud) / 2))

    return {
        width         = width,
        height        = height,
        umbra_draw    = rectangle(w + 2*ud, h + 2*ud, r_umb, corner, shift, shift),
        penumbra_draw = rectangle(w + 2*pd, h + 2*pd, r_pen, corner, shift, shift),
    }
end

-- Soften mask edges before final write (IM units).
local IM_MASK_BORDER_PX <const> = 3
local IM_MASK_BLUR <const>      = "0x2.0"

-- Render the penumbra and umbra masks into one cached PNG.
local function render_shadow_png(spec, masks, outfile)
    local shadowcolor = spec.shadowcolor
    local blankcolor  = spec.blankcolor

    local mask_fmt = "-size %dx%d -depth 8 xc:none -fill black -stroke none -draw %s"
    local pmask = format(mask_fmt, masks.width, masks.height, shell_quote(masks.penumbra_draw))
    local umask = format(mask_fmt, masks.width, masks.height, shell_quote(masks.umbra_draw))

    local shadow_fmt = "-background %s -shadow %dx%d+0+0 +repage"
    local pshadow = format(shadow_fmt, shell_quote(shadowcolor), spec.palpha, spec.psigma)
    local ushadow = format(shadow_fmt, shell_quote(shadowcolor), spec.ualpha, spec.usigma)

    local parts = { "magick" }

    if spec.use_penumbra then
        insert(parts, "\\(")
        insert(parts, pmask)
        insert(parts, "\\)")
        insert(parts, "\\( +clone")
        insert(parts, pshadow)
        insert(parts, "\\)")
    end

    if spec.use_umbra then
        insert(parts, "\\(")
        insert(parts, umask)
        insert(parts, "\\)")
        insert(parts, "\\( +clone")
        insert(parts, ushadow)
        insert(parts, "\\)")
    end

    if spec.use_penumbra and spec.use_umbra then
        insert(parts, "-delete 0,2")
        insert(parts, format("-background %s -channel Alpha -gravity Center -compose Lighten -composite", shell_quote(shadowcolor)))
    elseif spec.use_penumbra or spec.use_umbra then
        insert(parts, "-delete 0")
    else
        return false
    end

    insert(parts, format("\\( +clone -bordercolor %s -compose Src -border %d -channel Alpha -blur %s \\) -delete 0", shell_quote(blankcolor), IM_MASK_BORDER_PX, IM_MASK_BLUR))
    insert(parts, format("-units PixelsPerInch -density %d -quality 00 +set date:create +set date:modify", spec.resolution))
    insert(parts, format("-colorspace %s", spec.colorspace))
    insert(parts, shell_quote(outfile))

    local cmd = table.concat(parts, " ")

    report("%s", cmd)
    os.execute(cmd)
    if not isfile(outfile) then
        report("missing output %s", outfile)
        return false
    end
    return true
end

local function build_stamp(spec, masks)
    local stamp = table.concat({
        spec.width, spec.height, spec.backgroundradius,
        spec.udistance, spec.pdistance, spec.usigma, spec.psigma,
        spec.ualpha, spec.palpha, spec.resolution,
        spec.use_umbra and "u1" or "u0",
        spec.use_penumbra and "p1" or "p0",
        spec.shadowcolor,
        spec.direction, spec.offset,
        spec.backgroundcorner,
    }, "|")

    if masks and masks.umbra_draw and masks.penumbra_draw then
        stamp = stamp .. "|" .. masks.umbra_draw .. "|" .. masks.penumbra_draw
    end
    return stamp
end

local function render_to_file(spec, masks)
    local directory = collapsepath(spec.directory or "") or "."
    if not isdir(directory) then mkdirs(directory) end

    local stamp = build_stamp(spec, masks)
    local hash    = job.variables.makechecksum(stamp)
    local outfile = file.join(directory, format("%s-temp-%s.png", tex.jobname, hash))

    if not spec.force and isfile(outfile) then return outfile end
    if render_shadow_png(spec, masks, outfile) then return outfile end
    return nil
end

function externalshadow.render(spec)
    return render_to_file(spec, box_masks(spec))
end

local shadowlayer_keys = { "blur", "spread", "transparency" }

local function clamp_transparency(n)
    n = tonumber(n)
    if not n then
        return 0.5
    end
    return max(0, min(1, n))
end

local function opacity_from_transparency(n)
    return round(100 * (1 - clamp_transparency(n)))
end

local function resolve_shadowlayer(name)
    local namespace = getmacro("????shadowlayer") or ""
    local base      = namespace .. ":"
    local resolved  = {
        blur         = getmacro(base .. "blur"),
        spread       = getmacro(base .. "spread"),
        transparency = getmacro(base .. "transparency"),
    }
    local layername = name or ""

    if layername == "" then
        return nil
    end

    local instance = namespace .. layername .. ":"
    for _, k in ipairs(shadowlayer_keys) do
        local v = getmacro(instance .. k)
        if v ~= nil then
            resolved[k] = v
        end
    end

    return resolved
end

local function options_to_spec(options)
    local resolution = tonumber(options.resolution) or 150

    local umbra_layer    = resolve_shadowlayer(options.umbra)
    local penumbra_layer = resolve_shadowlayer(options.penumbra)

    local use_umbra    = umbra_layer ~= nil
    local use_penumbra = penumbra_layer ~= nil

    local ualpha = use_umbra    and opacity_from_transparency(umbra_layer.transparency) or 0
    local palpha = use_penumbra and opacity_from_transparency(penumbra_layer.transparency) or 0

    local ud_px = use_umbra    and dimen_to_px(umbra_layer.spread, resolution) or 0
    local pd_px = use_penumbra and dimen_to_px(penumbra_layer.spread, resolution) or 0

    if pd_px < ud_px then pd_px = ud_px end

    local shadowcolor, colorspace = color_to_im(options.shadowcolor or "black", 1)
    local blankcolor = color_to_im(options.shadowcolor or "black", 0)

    return {
        directory        = options.directory or "",
        width            = dimen_to_px(options.width, resolution),
        height           = dimen_to_px(options.height, resolution),
        ualpha           = ualpha,
        palpha           = palpha,
        usigma           = use_umbra    and max(0, dimen_to_px(umbra_layer.blur, resolution)) or 0,
        psigma           = use_penumbra and max(0, dimen_to_px(penumbra_layer.blur, resolution)) or 0,
        udistance        = ud_px,
        pdistance        = pd_px,
        use_umbra        = use_umbra,
        use_penumbra     = use_penumbra,
        direction        = options.direction,
        offset           = options.offset,
        resolution       = resolution,
        shadowcolor      = shadowcolor,
        blankcolor       = blankcolor,
        colorspace       = colorspace,
        backgroundcorner = options.backgroundcorner,
        backgroundradius = dimen_to_px(options.backgroundradius, resolution),
        force            = options.force == v_yes,
    }
end

function externalshadow.use(name, options)
    options = options or { }
    local spec = options_to_spec(options)
    local hoff, voff = placement_sp(options.direction, options.offset)

    local layerspec = { format("layer:%s", name) }

    local locationspec = {
        x = format("%dsp", hoff),
        y = format("%dsp", voff),
    }

    local formatspec = {
        width    = options.width,
        height   = options.height,
        corner   = v_middle,
        location = v_middle,
    }

    local backgroundspec = {
        width            = options.width,
        height           = options.height,
        frame            = v_off,
        background       = v_color,
        backgroundcorner = options.backgroundcorner,
        backgroundradius = options.backgroundradius,
        backgroundcolor  = options.backgroundcolor,
    }

    local filename = externalshadow.render(spec)
    if filename then
        context.definelayer(layerspec, formatspec)
        context.setlayer(layerspec, locationspec, context.nested.externalfigure{filename})
        context.setlayerframed(layerspec, {}, backgroundspec, context.nested(""))
        context.flushlayer(layerspec)
    end
end

local keys = {
    "umbra", "penumbra",
    "direction", "offset", "resolution", "shadowcolor", "backgroundcolor", "fillcolor", "force", "directory",
}

local function resolve_options(options)
    local namespace = getmacro("????externalshadow") or ""
    local preset    = rawget(options, "preset") or ""

    if preset ~= "" then
        local instance = namespace .. preset .. ":"
        for _, k in ipairs(keys) do
            if rawget(options, k) == nil then
                local v = getmacro(instance .. k)
                if v ~= nil then
                    options[k] = v
                end
            end
        end
    end

    local base = namespace .. ":"
    for _, k in ipairs(keys) do
        if rawget(options, k) == nil then
            options[k] = getmacro(base .. k)
        end
    end
end

-- Turn a scanned MetaPost path into an SVG-style path string for ImageMagick.
local function path_to_svg(path, fx, fy)
    local n = path and #path or 0
    if n == 0 then return nil end

    local function num(v) return format("%.3f", v) end

    local out = { format("M %s,%s", num(fx(path[1][1])), num(fy(path[1][2]))) }

    local function append_curve(prev, curr)
        insert(out, format("C %s,%s %s,%s %s,%s",
            num(fx(prev[5])), num(fy(prev[6])), -- right control of prev
            num(fx(curr[3])), num(fy(curr[4])), -- left control of curr
            num(fx(curr[1])), num(fy(curr[2])))) -- knot point of curr
    end

    for i = 2, n do
        append_curve(path[i-1], path[i])
    end
    if path.cycle and n >= 2 then
        append_curve(path[n], path[1])
        insert(out, "Z")
    end
    return table.concat(out, " ")
end

local function path_masks(spec, path, xmin, ymin, xmax, ymax)
    local res = spec.resolution
    local pad = max(spec.udistance + 2 * spec.usigma, spec.pdistance + 2 * spec.psigma) + 1
    local s   = res / 72

    local path_w_px = round((xmax - xmin) * s)
    local path_h_px = round((ymax - ymin) * s)

    local width  = path_w_px + 2 * pad
    local height = path_h_px + 2 * pad

    local function fx(x) return (x - xmin) * s + pad end
    local function fy(y) return (ymax - y) * s + pad end -- y-flip for IM

    local svg = path_to_svg(path, fx, fy)
    if not svg then return nil end

    local function outset_draw(distance)
        if distance > 0 then
            return format(
                "fill black stroke black stroke-width %d stroke-linejoin round stroke-linecap round fill-rule nonzero path '%s'",
                2 * distance, svg)
        else
            return format("fill black fill-rule nonzero path '%s'", svg)
        end
    end

    return {
        width         = width,
        height        = height,
        umbra_draw    = outset_draw(spec.udistance),
        penumbra_draw = outset_draw(spec.pdistance),
    }
end

function mp.externalshadow_use(xmin, ymin, xmax, ymax)
    local options = getparameterset("externalshadow")
    resolve_options(options)
    local spec    = options_to_spec(options)
    local path    = options.path

    local masks = path_masks(spec, path, xmin, ymin, xmax, ymax)
    if not masks then
        return [[image(nullpicture)]]
    end

    local outfile = render_to_file(spec, masks)
    if not outfile then
        return [[image(nullpicture)]]
    end

    local sp_per_bp  = tex.sp("1bp")
    local hoff, voff = placement_sp(options.direction, options.offset)

    -- ImageMagick expands the PNG for the blur, so center the loaded figure
    -- in MetaPost and then restore the path's logical bounds.
    local cx   = (xmin + xmax) / 2
    local cy   = (ymin + ymax) / 2
    local w_bp = xmax - xmin
    local h_bp = ymax - ymin

    return format(
        [[image (
            newpicture fp ; fp := figure("%s") ;
            draw fp shifted (-center fp) shifted (%fbp, %fbp) ;
            setbounds currentpicture to fullsquare xscaled %fbp yscaled %fbp shifted (%fbp, %fbp) ;
        ) shifted (%fbp, %fbp)]],
        outfile,
        cx, cy,
        w_bp, h_bp, cx, cy,
        hoff/sp_per_bp, -voff/sp_per_bp
    )
end

function mp.externalshadow_fillcolor()
    local options = getparameterset("externalshadow")
    resolve_options(options)
    return format("%q", options.fillcolor or "")
end

interfaces.implement {
    name      = "useexternalshadow",
    actions   = function(options)
        externalshadow.use(options.name, options)
    end,
    arguments = {{
        { "name" },
        { "preset" },
        { "directory" },
        { "width" },
        { "height" },
        { "umbra" },
        { "penumbra" },
        { "direction" },
        { "offset" },
        { "resolution" },
        { "shadowcolor" },
        { "fillcolor" },
        { "backgroundcorner" },
        { "backgroundradius" },
        { "backgroundcolor" },
        { "force" },
    }},
}
