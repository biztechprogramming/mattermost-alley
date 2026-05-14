package main

import (
	"bytes"
	"image"
	"image/color"
	stdraw "image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
	xdraw "golang.org/x/image/draw"
)

type config struct {
	Enabled             bool
	MaxDimension        int
	JpegQuality         int
	RejectVideosAndPDFs bool
	RejectMessage       string
}

var blockedExtensions = map[string]bool{
	".pdf":  true,
	".mp4":  true,
	".m4v":  true,
	".mov":  true,
	".mkv":  true,
	".webm": true,
	".avi":  true,
	".wmv":  true,
	".flv":  true,
	".mpg":  true,
	".mpeg": true,
	".3gp":  true,
	".ogv":  true,
	".ts":   true,
}

const defaultRejectMessage = "This file type isn't allowed in this chat. Please convert it to an image, or share a link instead."

type Plugin struct {
	plugin.MattermostPlugin

	mu  sync.RWMutex
	cfg *config
}

func (p *Plugin) OnConfigurationChange() error {
	c := &config{}
	if err := p.API.LoadPluginConfiguration(c); err != nil {
		return err
	}
	if c.MaxDimension <= 0 {
		c.MaxDimension = 1280
	}
	if c.JpegQuality <= 0 || c.JpegQuality > 100 {
		c.JpegQuality = 80
	}
	if c.RejectMessage == "" {
		c.RejectMessage = defaultRejectMessage
	}
	p.mu.Lock()
	p.cfg = c
	p.mu.Unlock()
	return nil
}

func (p *Plugin) get() config {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.cfg == nil {
		return config{
			Enabled: true, MaxDimension: 1280, JpegQuality: 80,
			RejectVideosAndPDFs: true, RejectMessage: defaultRejectMessage,
		}
	}
	return *p.cfg
}

// FileWillBeUploaded intercepts every upload (web, mobile, desktop all hit the
// same server code path) and either rejects it outright (videos / PDFs) or
// rewrites the bytes (oversized images). Returning (nil, "") tells the server
// to keep the original.
func (p *Plugin) FileWillBeUploaded(_ *plugin.Context, info *model.FileInfo, file io.Reader, output io.Writer) (*model.FileInfo, string) {
	cfg := p.get()
	if !cfg.Enabled {
		return nil, ""
	}

	data, err := io.ReadAll(file)
	if err != nil {
		return nil, ""
	}

	contentType := http.DetectContentType(data)
	ext := strings.ToLower(filepath.Ext(info.Name))

	if cfg.RejectVideosAndPDFs {
		if strings.HasPrefix(contentType, "video/") ||
			contentType == "application/pdf" ||
			blockedExtensions[ext] {
			p.API.LogInfo("upload-policy rejected file",
				"name", info.Name, "content_type", contentType, "ext", ext)
			return nil, cfg.RejectMessage
		}
	}

	if !strings.HasPrefix(contentType, "image/") {
		mustWrite(output, data)
		return nil, ""
	}

	imgCfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		mustWrite(output, data)
		return nil, ""
	}

	longest := imgCfg.Width
	if imgCfg.Height > longest {
		longest = imgCfg.Height
	}
	tooBig := longest > cfg.MaxDimension

	convertToJPEG := false
	switch {
	case strings.HasPrefix(contentType, "image/jpeg"):
		if !tooBig {
			mustWrite(output, data)
			return nil, ""
		}
	case contentType == "image/png":
		if !tooBig {
			mustWrite(output, data)
			return nil, ""
		}
		convertToJPEG = true
	case contentType == "image/gif":
		if !tooBig {
			mustWrite(output, data)
			return nil, ""
		}
		convertToJPEG = true
	default:
		mustWrite(output, data)
		return nil, ""
	}

	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		mustWrite(output, data)
		return nil, ""
	}

	dstW, dstH := scaled(imgCfg.Width, imgCfg.Height, cfg.MaxDimension)
	dst := image.NewRGBA(image.Rect(0, 0, dstW, dstH))

	if convertToJPEG {
		stdraw.Draw(dst, dst.Bounds(), &image.Uniform{C: color.White}, image.Point{}, stdraw.Src)
		xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, src.Bounds(), stdraw.Over, nil)
	} else {
		xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, src.Bounds(), stdraw.Src, nil)
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: cfg.JpegQuality}); err != nil {
		mustWrite(output, data)
		return nil, ""
	}

	if buf.Len() >= len(data) && !convertToJPEG {
		mustWrite(output, data)
		return nil, ""
	}

	if _, err := output.Write(buf.Bytes()); err != nil {
		return nil, ""
	}

	newInfo := *info
	newInfo.Size = int64(buf.Len())
	newInfo.Width = dstW
	newInfo.Height = dstH
	newInfo.MimeType = "image/jpeg"
	if convertToJPEG {
		if ext != ".jpg" && ext != ".jpeg" {
			base := strings.TrimSuffix(newInfo.Name, filepath.Ext(newInfo.Name))
			newInfo.Name = base + ".jpg"
			newInfo.Extension = "jpg"
		}
	}

	p.API.LogDebug("upload-policy rewrote image",
		"orig_bytes", len(data),
		"new_bytes", buf.Len(),
		"orig_dims", []int{imgCfg.Width, imgCfg.Height},
		"new_dims", []int{dstW, dstH},
		"orig_type", contentType,
		"converted_to_jpeg", convertToJPEG,
	)

	return &newInfo, ""
}

func scaled(w, h, maxDim int) (int, int) {
	if w >= h {
		nh := int(float64(h) * float64(maxDim) / float64(w))
		if nh < 1 {
			nh = 1
		}
		return maxDim, nh
	}
	nw := int(float64(w) * float64(maxDim) / float64(h))
	if nw < 1 {
		nw = 1
	}
	return nw, maxDim
}

func mustWrite(w io.Writer, b []byte) {
	_, _ = w.Write(b)
}

func main() {
	plugin.ClientMain(&Plugin{})
}
