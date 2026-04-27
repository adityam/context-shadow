modules = modules or { }
modules["t-shadow"] = {
    version = "2026.04.23",
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

local variables = interfaces.variables

local v_middle <const> = variables.middle
local v_round  <const> = variables.round
local v_color  <const> = variables.color
local v_yes    <const> = variables.yes
local v_no     <const> = variables.no
local v_off    <const> = variables.off

local report = logs.reporter("shadow")

local function shell_quote(p)
    return "'" .. gsub(p, "'", "'\\''") .. "'"
end

local function dimen_to_px(n, resolution)
    if n == nil or n == "" then return 0 end
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

local function rectangle(w, h, rpx, corner)
    local x, y = max(1, w), max(1, h)
    if corner == v_round and rpx > 0 then
        return format("roundrectangle 1,1 %d,%d %d,%d", x, y, rpx, rpx)
    end
    return format("rectangle 1,1 %d,%d", x, y)
end

local function create_shadow_png(spec, outfile)
    local w, h   = spec.width, spec.height
    local ud, pd = spec.udistance, spec.pdistance
    local rpx    = spec.backgroundradius

    local shadowcolor = spec.shadowcolor
    local blankcolor  = spec.blankcolor
    local corner      = spec.backgroundcorner

    local cw = w + 2 * max(pd, ud) + 2
    local ch = h + 2 * max(pd, ud) + 2

    local r_pen = min(rpx, floor(min(w + 2*pd, h + 2*pd) / 2))
    local r_umb = min(rpx, floor(min(w + 2*ud, h + 2*ud) / 2))

    local mask_fmt = "-size %dx%d -depth 8 xc:none -fill black -stroke none -draw %s"
    local pmask = format(mask_fmt, cw, ch, shell_quote(rectangle(w + 2*pd, h + 2*pd, r_pen, corner)))
    local umask = format(mask_fmt, cw, ch, shell_quote(rectangle(w + 2*ud, h + 2*ud, r_umb, corner)))

    local shadow_fmt = "-background %s -shadow %dx%d+0+0 +repage"
    local pshadow = format(shadow_fmt, shell_quote(shadowcolor), spec.penumbra, spec.psigma)
    local ushadow = format(shadow_fmt, shell_quote(shadowcolor), spec.umbra,    spec.usigma)

    local cmd = table.concat({
        "magick",
        "\\(", pmask, "\\)", "\\( +clone", pshadow, "\\)",
        "\\(", umask, "\\)", "\\( +clone", ushadow, "\\)",
        "-delete 0,2",
        format("-background %s -channel Alpha -gravity Center -compose Lighten -composite", shell_quote(shadowcolor)),
        format("\\( +clone -bordercolor %s -compose Src -border 3 -channel Alpha -blur 0x2.0 \\) -delete 0", shell_quote(blankcolor)),
        format("-units PixelsPerInch -density %d -quality 00 +set date:create +set date:modify", spec.resolution),
        format("-colorspace %s", spec.colorspace),
        shell_quote(outfile),
    }, " ")

    report("%s", cmd)
    os.execute(cmd)
    if not isfile(outfile) then
        report("missing output %s", outfile)
        return false
    end
    return true
end

local function build_stamp(spec)
    return table.concat({
        spec.width, spec.height, spec.backgroundradius,
        spec.udistance, spec.pdistance, spec.usigma, spec.psigma,
        spec.umbra, spec.penumbra, spec.resolution,
        spec.shadowcolor,
        spec.direction, spec.offset,
        spec.backgroundcorner,
    }, "|")
end

function externalshadow.render(spec)
    local directory = collapsepath(spec.directory or "") or "."
    if not isdir(directory) then mkdirs(directory) end

    local hash = job.variables.makechecksum(build_stamp(spec))
    local outfile = file.join(directory, format("%s-temp-%s.png", tex.jobname, hash))

    if not spec.force and isfile(outfile) then return outfile end
    if create_shadow_png(spec, outfile) then return outfile end
    return nil
end

local function options_to_spec(options)
    local resolution = tonumber(options.resolution) or 150
    
    -- umbra and penumbra are percentages between 0 and 100
    local umbra    = max(0, min(100, tonumber(options.umbra) or 50))
    local penumbra = max(0, min(100, tonumber(options.penumbra) or 40))

    local ud_px = dimen_to_px(options.udistance, resolution)
    local pd_px = dimen_to_px(options.pdistance, resolution)
    if pd_px < ud_px then pd_px = ud_px end

    local shadowcolor, colorspace = color_to_im(options.shadowcolor or "black", 1)
    local blankcolor = color_to_im(options.shadowcolor or "black", 0)

    return {
        directory        = options.directory or "",
        width            = dimen_to_px(options.width, resolution),
        height           = dimen_to_px(options.height, resolution),
        umbra            = umbra,
        penumbra         = penumbra,
        usigma           = max(0, dimen_to_px(options.usigma, resolution)),
        psigma           = max(0, dimen_to_px(options.psigma, resolution)),
        udistance        = ud_px,
        pdistance        = pd_px,
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

    local layerspec = {format("layer:%s", name)}

    local locationspec = {
             x=format("%dsp",hoff), 
             y=format("%dsp",voff)
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

interfaces.implement {
    name      = "useexternalshadow",
    actions   = function(options)
        externalshadow.use(options.name, options)
    end,
    arguments = {{
        { "name" },
        { "directory" },
        { "width" },
        { "height" },
        { "umbra" },
        { "penumbra" },
        { "usigma" },
        { "psigma" },
        { "udistance" },
        { "pdistance" },
        { "direction" },
        { "offset" },
        { "resolution" },
        { "shadowcolor" },
        { "backgroundcorner"},
        { "backgroundradius" },
        { "backgroundcolor" },
        { "force" },
    }},
}
