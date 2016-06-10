CREATE OR REPLACE FUNCTION road_class(type TEXT)
RETURNS TEXT AS $$
BEGIN
	RETURN CASE
		WHEN type IN ('tertiary') THEN 'tertiary'
		WHEN type IN ('trunk') THEN 'trunk'
		WHEN type IN ('steps','corridor','crossing','piste','mtb','hiking','cycleway','footway','path','bridleway') THEN 'path'
		WHEN type IN ('platform') THEN 'pedestrian'
		WHEN type IN ('secondary') THEN 'secondary'
		WHEN type IN ('service') THEN 'service'
		WHEN type IN ('construction') THEN 'construction'
		WHEN type IN ('track') THEN 'track'
		WHEN type IN ('primary') THEN 'primary'
		WHEN type IN ('motorway') THEN 'motorway'
		WHEN type IN ('rail','light_rail','subway') THEN 'major_rail'
		WHEN type IN ('hole') THEN 'golf'
		WHEN type IN ('cable_car','gondola','mixed_lift','chair_lift','drag_lift','t-bar','j-bar','platter','rope_tow','zip_line','magic_carpet','canopy') THEN 'aerialway'
		WHEN type IN ('motorway_link') THEN 'motorway_link'
		WHEN type IN ('ferry') THEN 'ferry'
		WHEN type IN ('trunk_link','primary_link','secondary_link','tertiary_link') THEN 'link'
		WHEN type IN ('unclassified','residential','road','living_street','raceway') THEN 'street'
	END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION city_class(type TEXT)
RETURNS TEXT AS $$
BEGIN
	RETURN CASE
		WHEN type IN ('administrative', 'postal_code') THEN 'boundary'
		WHEN type IN ('city','borough','suburb','quarter','neighbourhood','town','village','hamlet') THEN 'place'
		WHEN type IN ('residential') THEN 'landuse'
	END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


CREATE OR REPLACE FUNCTION countryName(partition_id int) returns TEXT as $$
	SELECT COALESCE(name -> 'name:en',name -> 'name') FROM country_name WHERE partition = partition_id;
$$ language 'sql';


CREATE OR REPLACE FUNCTION getHierarchyAsTextArray(int[])
RETURNS character varying[] AS $$
DECLARE
  retVal character varying[];
  x int;
BEGIN
IF $1 IS NOT NULL
THEN
    FOREACH x IN ARRAY $1
    LOOP
      retVal := array_append(retVal, (SELECT COALESCE(NULLIF(name_en,''), name)::character varying FROM osm_polygon WHERE id = x));
    END LOOP;
END IF;
RETURN retVal;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION constructDisplayName(id_value BIGINT, delimiter TEXT) RETURNS TEXT AS $$
DECLARE
  displayName TEXT;
  oldName TEXT;
  currentName TEXT;
  current_id BIGINT;
BEGIN
  current_id := id_value;
  WHILE current_id IS NOT NULL LOOP
    SELECT parent_id, COALESCE(NULLIF(name_en,''), name) FROM osm_polygon WHERE id = current_id INTO current_id, currentName;
    IF displayName IS NULL THEN
	displayName := currentName;
    ELSE
    	displayName := displayName || delimiter || ' ' || currentName;
    END IF;
  END LOOP;
RETURN displayName;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION constructNodeDisplayName(id_value BIGINT, delimiter TEXT, name TEXT) RETURNS TEXT AS $$
DECLARE
  displayName TEXT;
BEGIN
	SELECT constructDisplayName(id_value) INTO displayName;
	displayName := name || delimiter || ' ' || displayName;
	IF displayName IS NULL THEN
		return '';
	END IF;
RETURN displayName;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION constructSpecificParentName(id_value BIGINT, from_rank INTEGER, to_rank INTEGER) RETURNS TEXT AS $$
DECLARE
  current_id BIGINT;
  currentName TEXT;
  currentNameOld TEXT;
  current_rank INTEGER;
BEGIN
  current_rank := from_rank;
  current_id := id_value;
  currentName := '';
  currentNameOld := '';
  IF current_rank = to_rank THEN
    SELECT COALESCE(NULLIF(name_en,''), name) FROM osm_polygon WHERE id = current_id INTO currentName;
    RETURN currentName;
  END IF; 
  WHILE current_rank > to_rank  LOOP
  currentNameOld := currentName;
    SELECT parent_id, COALESCE(NULLIF(name_en,''), name), rank_search FROM osm_polygon WHERE id = current_id INTO current_id, currentName, current_rank;
    IF current_id IS NULL THEN
	RETURN '';
    END IF; 
      IF current_rank < to_rank THEN
	RETURN currentNameOld;
    END IF; 
  END LOOP;
RETURN currentName;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION determineParentPlace(id_value BIGINT, partition_value INT, rank_search_value INT, geometry_value GEOMETRY) RETURNS BIGINT AS $$
DECLARE
  retVal BIGINT;
BEGIN
  FOR current_rank  IN REVERSE rank_search_value..1 LOOP
     SELECT id FROM osm_polygon WHERE partition=partition_value AND rank_search = current_rank AND NOT id=id_value AND ST_Contains(geometry, geometry_value) INTO retVal;
     IF retVal IS NOT NULL THEN
      return retVal;
    END IF;
  END LOOP;
RETURN retVal;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION findRoadsWithinGeometry(id_value integer,partition_value integer, geometry_value GEOMETRY) RETURNS BIGINT AS $$
DECLARE
  retVal BIGINT;
BEGIN
retVal := 1;
	UPDATE osm_linestring SET parent_id = id_value WHERE parent_id IS NULL AND ST_Contains(geometry_value,geometry);
RETURN id_value;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION determineRoadHierarchyForEachCountry() RETURNS BIGINT AS $$
DECLARE
  retVal BIGINT;
BEGIN
  FOR current_partition  IN 1..255 LOOP
    FOR current_rank  IN REVERSE 22..4 LOOP
       PERFORM findRoadsWithinGeometry(id, current_partition, geometry) FROM osm_polygon WHERE partition = current_partition AND rank_search = current_rank;
    END LOOP;
  END LOOP;
RETURN retVal;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_country_language_code(search_country_code VARCHAR(2)) RETURNS TEXT
  AS $$
DECLARE
  nearcountry RECORD;
BEGIN
  FOR nearcountry IN select distinct country_default_language_code from country_name where country_code = search_country_code limit 1
  LOOP
    RETURN lower(nearcountry.country_default_language_code);
  END LOOP;
  RETURN NULL;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION get_country_code(place geometry) RETURNS TEXT
  AS $$
DECLARE
  place_centre GEOMETRY;
  nearcountry RECORD;
BEGIN
  place_centre := ST_PointOnSurface(place);

  FOR nearcountry IN select country_code from country_osm_grid where st_covers(geometry, place_centre) order by area asc limit 1
  LOOP
    RETURN nearcountry.country_code;
  END LOOP;

  FOR nearcountry IN select country_code from country_osm_grid where st_dwithin(geometry, place_centre, 0.5) order by st_distance(geometry, place_centre) asc, area asc limit 1
  LOOP
    RETURN nearcountry.country_code;
  END LOOP;

  RETURN NULL;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION get_partition(in_country_code character varying(2)) RETURNS INTEGER
  AS $$
DECLARE
  nearcountry RECORD;
BEGIN
  FOR nearcountry IN select partition from country_name where country_code = in_country_code
  LOOP
    RETURN nearcountry.partition;
  END LOOP;
  RETURN 0;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION getImportance(rank_search int, wikipedia character varying, country_code VARCHAR(2)) returns double precision as $$

DECLARE
  langs TEXT[];
  i INT;
  wiki_article_title TEXT;
  wiki_article_language TEXT;
  result double precision;
BEGIN

  wiki_article_title := replace(split_part(wikipedia, ':', 2),' ','_');
  wiki_article_language := split_part(wikipedia, ':', 1);

  SELECT importance FROM wikipedia_article WHERE language = wiki_article_language AND title = wiki_article_title ORDER BY importance DESC LIMIT 1 INTO result;
  IF result IS NOT NULL THEN
    return result;
  END IF;

  langs := ARRAY['english','country','ar','bg','ca','cs','da','de','en','es','eo','eu','fa','fr','ko','hi','hr','id','it','he','lt','hu','ms','nl','ja','no','pl','pt','kk','ro','ru','sk','sl','sr','fi','sv','tr','uk','vi','vo','war','zh'];
  i := 1;

  WHILE langs[i] IS NOT NULL LOOP

	-- try default language for this country, English and then every other language for possible match
    wiki_article_language := CASE WHEN langs[i] = 'english' THEN 'en' WHEN langs[i] = 'country' THEN get_country_language_code(country_code) ELSE langs[i] END;

  SELECT importance FROM wikipedia_article WHERE language = wiki_article_language AND title = wiki_article_title ORDER BY importance DESC LIMIT 1 INTO result;
    IF result IS NOT NULL THEN
      return result;
    END IF;

      IF result IS NOT NULL THEN
        return result;
      END IF;
    i := i + 1;
  END LOOP;
  -- return default calculated value if no match found  
    IF rank_search IS NOT NULL THEN
      return 0.75-(rank_search::double precision/40);
    END IF;
  RETURN NULL;
END;
$$
LANGUAGE plpgsql;