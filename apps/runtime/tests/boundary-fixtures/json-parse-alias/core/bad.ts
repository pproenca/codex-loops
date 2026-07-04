const parse = JSON.parse
const { parse: parseAgain } = JSON

export function bad(text: string) {
  return [parse(text), parseAgain(text)]
}
