import argparse
import json
import os

def parse_uci(uci_file):
  st = {}

  with open(uci_file) as lines:
    for line in filter(lambda x: x != "", lines):
      [path, value] = line.strip().split("=", maxsplit=1)
      entry = list(filter(lambda x: x not in ["", " "], value.split("'")))
      if len(entry) == 1:
        entry = entry[0]

      split = path.split(".")
      if len(split) == 2:
        [module, name] = split
        if module not in st:
          st[module] = {}
        if name not in st[module]:
          st[module][name] = {"options": {}}
        st[module][name]["type"] = entry
      elif len(split) == 3:
        [module, name, opt] = split
        if module not in st:
          st[module] = {}
        if name not in st[module]:
          st[module][name] = {"options": {}}
        st[module][name]["options"][opt] = entry
      else:
        raise Exception(f"invalid input: {line}")

  # Assume source is auto-generated, with the anonymous entries in relative order
  return {
    module: [ {
      **v2,
      **({"name": k} if not k.startswith("@") else {})
    } for (k,v2) in v.items() ]
    for (module,v)
    in st.items()
  }


def main():
  parser = argparse.ArgumentParser(description="Parse UCI to json")
  parser.add_argument("--file", dest="file", metavar="FILE", type=str, help="path to UCI file to parse", required=True)
  parser.add_argument("--output", dest="output", metavar="FILE", type=str, help="output path for the json file", default=None)
  args = parser.parse_args()
  parsed = parse_uci(args.file)
  if args.output is None:
    print(parsed)
  else:
    with open(args.output, 'w', encoding="utf-8") as outfile:
      outfile.write(json.dumps(parsed, indent=2))


if __name__ == "__main__":
  main()
