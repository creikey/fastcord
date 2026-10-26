#!/bin/sh
# How the imagefmt test vectors were made (Homebrew: webp 1.6.0, libvpx, ImageMagick 7.1,
# jpeg-turbo 3.2, ffmpeg 9). Expected outputs in ../manifest.txt are FNV-1a-64 hashes of
# the *reference* decoder's RGBA, never of this package's output:
#   WebP still      dwebp -nodither -pam            (fancy upsampling, no dithering)
#   WebP animated   animdump.c (libwebpdemux WebPAnimDecoder, MODE_RGBA)
#   GIF             magick in.gif -coalesce -depth 8 rgba:-
#   PNG             magick in.png -depth 8 rgba:-
#   APNG            ffmpeg -i in.png -fps_mode passthrough -f rawvideo -pix_fmt rgba -
#                   (apng_hand.png is checked with tolerance 3: OVER-blend rounding differs)
#   JPEG            djpeg -rgb (libjpeg-turbo islow + fancy upsampling); EXIF/CMYK via magick -auto-orient / -colorspace sRGB
# Sources are synthetic (ImageMagick built-ins rose:/logo:/wizard:, plasma:fractal, gradients).
set -e
S=src; mkdir -p $S out
magick rose: $S/rose.png
magick -size 17x33 gradient:red-blue $S/odd.png
magick -seed 3 -size 128x128 plasma:fractal \( -size 128x128 xc:none -fill white -draw "circle 64,64 64,4" \) -alpha off -compose copy_opacity -composite $S/avatar.png
magick -seed 9 -size 48x48 plasma:fractal \( -size 48x48 xc:none -fill white -draw "circle 24,24 24,3" -fill "rgba(255,255,255,0.5)" -draw "rectangle 0,0 47,8" \) -alpha off -compose copy_opacity -composite -depth 8 $S/small_alpha.png
# WebP lossy/lossless option sweep (file names w_<img>.o<N>.webp use these, in order):
#   o1 -q 0 | o2 -q 100 | o9 -q 60 -nostrong | o10 -q 60 -strong -sharpness 7 | o13 -q 40 -alpha_q 20 -alpha_filter best
#   o18 -z 0 | o20 -z 9 | o21 -near_lossless 40
cwebp -q 0 $S/rose.png -o out/w_rose.o1.webp; cwebp -q 100 $S/rose.png -o out/w_rose.o2.webp
cwebp -q 60 -nostrong $S/odd.png -o out/w_odd.o9.webp; cwebp -q 60 -strong -sharpness 7 $S/rose.png -o out/w_rose.o10.webp
cwebp -q 40 -alpha_q 20 -alpha_filter best $S/avatar.png -o out/w_avatar.o13.webp
cwebp -z 0 $S/odd.png -o out/w_odd.o18.webp; cwebp -z 9 $S/rose.png -o out/w_rose.o20.webp; cwebp -near_lossless 40 $S/rose.png -o out/w_rose.o21.webp
cwebp -q 60 -alpha_method 0 $S/small_alpha.png -o out/t_sa_am0.webp; cwebp -q 60 -alpha_q 30 -alpha_filter best $S/small_alpha.png -o out/t_sa_filt.webp
cwebp -lossless $S/small_alpha.png -o out/t_sa_ll.webp
# libvpx key frames (multiple token partitions, other encoder's choices), wrapped in RIFF:
cc vpxkf.c -lvpx -o /tmp/vpxkf; magick $S/rose.png -alpha off rgba:/tmp/rose.raw
/tmp/vpxkf /tmp/rose.raw 70 46 /tmp/r.vp8 3 10 0 0 && python3 ivf2webp.py /tmp/r.vp8 out/v_rose.1.webp   # 8 partitions
# Animations: img2webp / gif2webp from 96x96 frames f0..f5 (alpha circles+rects) built with magick
#   img2webp -loop 3 -lossless -d 80 f0.png -d 5 f1.png f2.png -lossy -q 50 f3.png f4.png -d 300 f5.png -o a_mix.webp
#   img2webp -mixed -kmin 2 -kmax 4 f0..f5 -o a_kf.webp
#   magick -delay 10 -dispose previous f0 f1 f2 -dispose background f3 f4 -dispose none f5 -loop 0 -layers optimize g_opt.gif
#   gif2webp g_opt.gif -o a_fromgif.webp; gif2webp -mixed g_opt.gif -o a_fromgif_mixed.webp
#   ffmpeg -framerate 10 -i e%d.png -pred mixed -f apng ap_anim8m.png; python3 mkapng.py apng_hand.png
# PNG variants: magick rose.png -interlace PNG / -depth 16 / PNG8: / -colorspace gray -depth 1,2,4 /
#   -define png:compression-level=0 (stored deflate blocks) / tRNS via -define png:color-type=0,2
# JPEG: cjpeg [-progressive] [-sample 1x1|2x1|1x2|4x1|2x2] [-restart 3|1B] [-grayscale] [-optimize] [-rgb]
#   EXIF orientation: python3 exif.py in.jpg out.jpg <1..8> [be]; CMYK: magick in.jpg -colorspace cmyk
