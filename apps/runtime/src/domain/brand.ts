declare const provenSymbol: unique symbol
declare const brandSymbol: unique symbol

export type Proven<T> = T & {
  readonly [provenSymbol]: "proven"
}

export type Branded<T, Tag extends string> = T & {
  readonly [brandSymbol]: Tag
}
