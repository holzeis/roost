package api

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"os"
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

// isDark buckets a color as roughly dark or light — a coarse comparison
// deliberately more tolerant than exact RGB equality, since the preview
// below is JPEG-recompressed at a low quality (previewJPEGQuality), which
// perturbs individual pixel values slightly even for identical source
// content, but must never survive a 90° misrotation.
func isDark(c color.Color) bool {
	r, g, b, _ := c.RGBA()
	return (r+g+b)/3 < 0x8000
}

// TestGenerateImagePreview_AppliesEXIFOrientation guards against the real
// bug this once was: Go's stdlib image.Decode has no EXIF awareness at
// all, so a photo whose pixel data is stored in the camera sensor's own
// orientation (correct only once a viewer applies its EXIF Orientation
// tag) came out however the sensor happened to be held when the preview
// was generated — most visibly, an upside-down or sideways profile
// picture, since an avatar always renders the preview, never the
// untouched original (which still carries its own EXIF tag, so it
// displays correctly wherever it's shown directly).
//
// testdata/orientation_6.jpg is a real EXIF-tagged fixture (Orientation=6,
// "rotate 90° CW to display") borrowed from the imaging package's own test
// suite (github.com/disintegration/imaging, MIT licensed); orientation_0.jpg
// is the identical picture with no rotation needed at all. The two must
// decode to the same content once generateImagePreview has corrected the
// first one.
func TestGenerateImagePreview_AppliesEXIFOrientation(t *testing.T) {
	reference, err := os.ReadFile("testdata/orientation_0.jpg")
	if err != nil {
		t.Fatalf("read reference fixture: %v", err)
	}
	rotated, err := os.ReadFile("testdata/orientation_6.jpg")
	if err != nil {
		t.Fatalf("read rotated fixture: %v", err)
	}

	refImg, _, err := image.Decode(bytes.NewReader(reference))
	if err != nil {
		t.Fatalf("decode reference fixture: %v", err)
	}

	preview, width, height, ok := generateImagePreview(rotated)
	if !ok {
		t.Fatal("expected generateImagePreview to succeed on the EXIF-rotated fixture")
	}
	refBounds := refImg.Bounds()
	if width != refBounds.Dx() || height != refBounds.Dy() {
		t.Fatalf("expected corrected dimensions %dx%d, got %dx%d", refBounds.Dx(), refBounds.Dy(), width, height)
	}

	previewImg, _, err := image.Decode(bytes.NewReader(preview))
	if err != nil {
		t.Fatalf("decode generated preview: %v", err)
	}
	if previewImg.Bounds() != refBounds {
		t.Fatalf("expected bounds %v, got %v", refBounds, previewImg.Bounds())
	}
	for y := refBounds.Min.Y; y < refBounds.Max.Y; y++ {
		for x := refBounds.Min.X; x < refBounds.Max.X; x++ {
			if isDark(refImg.At(x, y)) != isDark(previewImg.At(x, y)) {
				t.Fatalf("pixel (%d,%d) mismatch between reference and corrected preview — orientation was not applied",
					x, y)
			}
		}
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
