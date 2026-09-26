package api

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
)

// testJPEG builds a real (non-trivial, so compression actually has
// something to do) JPEG of the given size, encoded at near-lossless
// quality — standing in for a real phone photo upload.
func testJPEG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			// A gradient plus per-pixel noise-like variation — a flat color
			// would compress to almost nothing regardless of quality,
			// which wouldn't actually exercise the size difference this
			// feature depends on.
			img.Set(x, y, color.RGBA{
				R: uint8((x * 7) % 256),
				G: uint8((y * 13) % 256),
				B: uint8((x*y + x + y) % 256),
				A: 255,
			})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatalf("encode test JPEG: %v", err)
	}
	return buf.Bytes()
}

func TestGenerateImagePreview_SameDimensionsSmallerFile(t *testing.T) {
	original := testJPEG(t, 400, 300)

	preview, width, height, ok := generateImagePreview(original)
	if !ok {
		t.Fatal("expected generateImagePreview to succeed on a valid JPEG")
	}
	// "Do not reduce the dimensions, just the quality" — the whole point.
	if width != 400 || height != 300 {
		t.Fatalf("expected dimensions unchanged at 400x300, got %dx%d", width, height)
	}
	if len(preview) >= len(original) {
		t.Fatalf("expected a smaller preview (faster to load) — original %d bytes, preview %d bytes",
			len(original), len(preview))
	}

	// The preview must still actually decode as a valid image, not just be
	// smaller.
	if _, _, err := image.Decode(bytes.NewReader(preview)); err != nil {
		t.Fatalf("preview does not decode as a valid image: %v", err)
	}
}

func TestGenerateImagePreview_UndecodableInputFallsBack(t *testing.T) {
	// Neither a real image nor anything image.Decode recognizes — matches
	// how an unsupported format (WebP/HEIC) or a corrupt upload fails.
	_, _, _, ok := generateImagePreview([]byte("not an image"))
	if ok {
		t.Fatal("expected generateImagePreview to report ok=false for undecodable input")
	}
}
