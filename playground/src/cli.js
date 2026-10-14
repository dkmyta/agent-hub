// node src/cli.js <command> <text> | truncate <maxLength> <text>
import { slugify, truncate, wordCount } from "./text.js";

const commands = { slugify, "word-count": wordCount };
const [command, ...words] = process.argv.slice(2);

function usage() {
  console.error(`Usage: node src/cli.js <${Object.keys(commands).join("|")}> <text>`);
  console.error("       node src/cli.js truncate <maxLength> <text>");
  process.exit(2);
}

if (command === "truncate") {
  const [max, ...rest] = words;
  const maxLength = Number(max);
  if (!Number.isInteger(maxLength) || maxLength < 1) usage();
  console.log(truncate(rest.join(" "), maxLength));
} else if (commands[command]) {
  console.log(commands[command](words.join(" ")));
} else {
  usage();
}
