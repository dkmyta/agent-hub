// Initials of a name: "Ada Lovelace" → "AL".
export function initials(name) {
  var words = name.split(" ");
  return words.map((word) => word[0].toUpperCase()).join("");
}
