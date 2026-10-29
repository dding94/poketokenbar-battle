"""Download pinned public PokéAPI CSVs into ignored cache; never read user saves."""
import concurrent.futures
import csv
import json
from pathlib import Path
import urllib.request

REFERENCE = '2bf639e5572812a67d2b94903fdcb9d095f5aeb2'
ROOT = Path(__file__).resolve().parents[1] / '.cache'
ROOT.mkdir(exist_ok=True)
NAMES = ['pokemon_moves', 'moves', 'version_groups', 'pokemon', 'pokemon_stats',
         'pokemon_types', 'pokemon_abilities', 'abilities', 'types', 'stats']

def fetch(name):
    path = ROOT / (name + '.csv')
    if not path.exists():
        url = f'https://raw.githubusercontent.com/PokeAPI/pokeapi/{REFERENCE}/data/v2/csv/{name}.csv'
        with urllib.request.urlopen(url, timeout=60) as response:
            path.write_bytes(response.read())
    return path

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch, NAMES))

def rows(name):
    with (ROOT / (name + '.csv')).open() as file:
        return list(csv.DictReader(file))

def identifiers(name):
    return {row['id']: row['identifier'] for row in rows(name)}

version = next(row['id'] for row in rows('version_groups') if row['identifier'] == 'black-2-white-2')
move_names = identifiers('moves')
eligible = {row['id'] for row in rows('pokemon') if int(row['species_id']) <= 649}
moves = sorted({move_names[row['move_id']] for row in rows('pokemon_moves')
                if row['version_group_id'] == version and row['pokemon_move_method_id'] == '1'
                and row['pokemon_id'] in eligible})
mon = {int(row['id']): {'num': int(row['id']), 'name': row['identifier'], 'stats': {}, 'types': [], 'abilities': []}
       for row in rows('pokemon') if int(row['id']) <= 649}
for table, field, source, lookup in [('pokemon_stats', 'stats', 'stat_id', 'stats'),
                                    ('pokemon_types', 'types', 'type_id', 'types'),
                                    ('pokemon_abilities', 'abilities', 'ability_id', 'abilities')]:
    names = identifiers(lookup)
    for row in rows(table):
        number = int(row['pokemon_id'])
        if number not in mon:
            continue
        name = names[row[source]]
        if field == 'stats':
            mon[number][field][name] = int(row['base_stat'])
        else:
            mon[number][field].append(name)
(ROOT / 'compat-input.json').write_text(json.dumps({'moves': moves, 'pokemon': list(mon.values())}))
print(f'Reference {REFERENCE}: {len(moves)} BW2 level-up moves, {len(mon)} species')
