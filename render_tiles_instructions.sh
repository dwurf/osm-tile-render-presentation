# Instructions to pre-render OSM tiles:

# Start with a clean Ubuntu Trusty 14.04 host

# Need postgis, importer and tools
sudo apt-get install postgresql-9.3 postgis osm2pgsql gdal-bin npm git curl xmlstarlet python-mapnik unzip
# Fonts
sudo apt-get install ttf-dejavu fonts-droid ttf-unifont fonts-sipa-arundina fonts-sil-padauk fonts-khmeros \
ttf-indic-fonts-core ttf-tamil-fonts ttf-kannada-fonts
# nginx -- for leaflet UI
sudo apt-get install nginx

# Fix node install
sudo ln -s /usr/bin/nodejs /usr/bin/node

# Install cartocss
sudo npm install -g carto millstone

# Grab the openstreetmap-carto repo, then fetch a few hundred MB of shapefiles
# (world boundaries and the like)
git clone https://github.com/gravitystorm/openstreetmap-carto.git
cd openstreetmap-carto
./get-shapefiles.sh

# Create the mapnik.xml style file
carto project.mml > mapnik.xml

# Tidy up some issues with the mapnik.xml file
# Despite the fonts being installed mapnik choked on some font styles. Remove them.
# This may cause some issues if you are rendering parts of India or Tibet. Unifont
# has a lower-case version so isn't affected.
xmlstarlet ed -L -d '/Map/FontSet/Font[contains(@face-name, "Mukti") or contains(@face-name, "TSCu_Paranar") or contains(@face-name, "Tibetan") or contains(@face-name, "Unifont Medium")]' mapnik.xml

# Need some data
cd ..
curl -O http://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf

# Set up the user and database in postgres. You will need to enter a password 
# here, so paste the lines one at a time
sudo -u postgres createuser -P gis
sudo -u postgres createdb -O gis gis

# Using sudo to avoid entering passwords. you can also use:
#  psql -h localhost -U gis gis
echo 'create extension postgis;' | sudo -u postgres psql gis
echo 'create extension hstore;' | sudo -u postgres psql gis

# Testing everything is ready
echo "create table blah(id integer, hstore hstore);" |
    sudo -u postgres psql gis
echo "select AddGeometryColumn('public', 'blah', 'geom', 4326, 'POINT', 2);" |
    sudo -u postgres psql gis
echo "drop table blah" |
    sudo -u postgres psql gis

# Load data. This takes 1.5 hours with the use of -s (--slim)
# Notes:
#   Use -s if you plan to use --append later (to update your database with OSM updates. 
#     Without this, the load will take about 10 minutes
#   If you want to change the prefix add -p <prefix>. Don't do this unless you know what 
#     you are doing -- you will have to modify mapnik.xml to match 
#     (you can probably use sed -i 's/planet_osm_/my_prefix_/g' mapnik.xml but this is untested)
cd openstreetmap-carto
time osm2pgsql -s -d gis -U gis -W -H localhost --style openstreetmap-carto.style -j ../australia-latest.osm.pbf

# Get the render scripts
curl -O https://raw.githubusercontent.com/openstreetmap/mapnik-stylesheets/master/generate_image.py
curl -O https://raw.githubusercontent.com/openstreetmap/mapnik-stylesheets/master/generate_tiles_multiprocess.py
chmod u+x generate_image.py generate_tiles_multiprocess.py

# Modify mapnik.xml to connect to our host/port
# Set the hostname
xmlstarlet ed -L -i '//Datasource/Parameter[@name="table"]' -t elem -n PostgisHost -v localhost -i '//PostgisHost' -t attr -n "name" -v "host" -r '//PostgisHost' -v 'Parameter' mapnik.xml
# Set the dbname
xmlstarlet ed -L -u '//Datasource/Parameter[@name="dbname"]' -v gis mapnik.xml
# Set the user
xmlstarlet ed -L -i '//Datasource/Parameter[@name="table"]' -t elem -n PostgisUser -v gis -i '//PostgisUser' -t attr -n "name" -v "user" -r '//PostgisUser' -v 'Parameter' mapnik.xml
# Set the password.
xmlstarlet ed -L -i '//Datasource/Parameter[@name="table"]' -t elem -n PostgisPassword -v password -i '//PostgisPassword' -t attr -n "name" -v "password" -r '//PostgisPassword' -v 'Parameter' mapnik.xml
# If your password is not 'password', you can change it here
#xmlstarlet ed -L -u '//Datasource/Parameter[@name="password"]' -v YourPasswordHere mapnik.xml

# Let's create a test image to make sure everything is set up correctly.
# In generate_image.py, change bounds to match the area you want to render.
# For a nice Melbourne CBD image, set the following:
#   bounds = (144.95, -37.80, 144.96, -37.83)
# 
#   z = 10
#   imgx = 600 * z
#   imgy = 500 * z
# 
# Now generate a test image
# (note: increasing the zoom level makes the png more detailed)
export MAPNIK_MAP_FILE=mapnik.xml
time ./generate_image.py

# Now let's get our render on!
mkdir -p tiles
export MAPNIK_TILE_DIR=tiles
export MAPNIK_MAP_FILE=mapnik.xml

# Delete old tiles if you don't want them
#rm -rf tiles/*

# Timings below are from a low power AMD quad core with 4 render processes
# Timings (in brackets) are from a 48-core render node with NUM_THREADS set to 48 and
# queue size set to 128

# In generate_tiles_multiprocess.py, set NUM_THREADS to the number of cores on your machine
# You might also have to change the length of the JoinableQueue up from 32 if you have a great 
# many cores

# Now clear out everything *after* the first render_tiles(bbox, ...) line
# In that line, change the 0 to 1, so it looks like this:
#    render_tiles(bbox, mapfile, tile_dir, 1, 5, "World")
# This will render the world at zoom level 1-5. Approx 20s (8s)

# Put the following in after the above code(Melbourne CBD area). Approx 15m (90s):
# Be very careful, the first latitude must be lower (MORE NEGATIVE!) than the second
# bbox = (144.95, -37.83, 144.96, -37.80)
# render_tiles(bbox, mapfile, tile_dir, 10, 18, "Melbourne CBD")

# Add these in as desired
# Be very careful, the first latitude must be lower (MORE NEGATIVE!) than the second
# Australia: 10 minutes (2 minutes)
# bbox = (108.0, -45.0, 155.0, -10.0)
# render_tiles(bbox, mapfile, tile_dir, 6, 10, "Australia")
# Victoria: 11 minutes (1 minute)
# bbox = (140.8, -39.3, 150.0, -33.9)
# render_tiles(bbox, mapfile, tile_dir, 11, 12, "Victoria")
# West Melbourne: 1h (4 minutes)
# bbox = (142.825, -38.231, 145.415, -37.033)
# render_tiles(bbox, mapfile, tile_dir, 13, 15, "West Melbourne")
# Beaufort-Lexton: 90m (6 minutes)
# bbox = (143.3503, -37.45769,  143.54496, -37.25739)
# render_tiles(bbox, mapfile, tile_dir, 16, 18, "Beaufort-Lexton")
 
time ./generate_tiles_multiprocess.py

# Now you can test how it works using leaflet and nginx
cd tiles
curl -O http://cdn.leafletjs.com/leaflet-0.7.3/leaflet.css -O http://cdn.leafletjs.com/leaflet-0.7.3/leaflet.js
cat > index.html << EOF 
<!doctype html>
<html style="height:100%">
<head>
    <link rel="stylesheet" href="leaflet.css" />
    <script src="leaflet.js"></script>
    <script type="text/javascript">
    function map_init() {
        var map = L.map('map').setView([-37.82, 144.95], 13);
        L.tileLayer('{z}/{x}/{y}.png', {
            attribution: 'Map data &copy; OpenStreetMap contributors',
            maxZoom: 18
        }).addTo(map);
    }
    </script>
</head>
<body style="padding: 0; margin: 0; height:100%;" onload="map_init();">
    <div id="map" style="height:100%"></div>
</body>
</html>
EOF

sudo bash -c "echo 'server {
    listen 80 default_server;
    root $(pwd);
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}' > /etc/nginx/sites-enabled/default"
sudo service nginx restart

## UPDATING THE MAP
# You can use josm to create new data on top of the map. Save your layer as .osm and import it into the db as follows:
#time osm2pgsql --append -s -d gis -U gis -W -H localhost --style=openstreetmap-carto.style -j update_file.osm
# Now you can re-render the area of interest and see your updates
