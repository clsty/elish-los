# Raw touch coordinates stay in the panel electrical frame (portrait: X 0..1599 /
# Y 0..2559) while the display is installed at 90 degrees, so the 90-degree difference
# has to be declared. Otherwise the input subsystem stretches them onto the logical
# viewport (RawToDisplay becomes SCALE) and touch is misaligned.
# The key must be touch.orientation: a bare "orientation" is the keyboard's key and is
# ignored on a touchscreen.
touch.orientation = ORIENTATION_90
