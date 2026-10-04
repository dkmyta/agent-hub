// node src/cli.js <command> <text>
import { slugify, wordCount } from "./text.js";

const commands = { slugify, "word-count": wordCount };
const [command, ...words] = process.argv.slice(2);

if (!commands[command]) {
  console.error(`Usage: node src/cli.js <${Object.keys(commands).join("|")}> <text>`);
  process.exit(2);
}
console.log(commands[command](words.join(" ")));
