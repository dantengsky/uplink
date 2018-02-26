transition initial -> set;
transition set -> terminal;

@initial
everything (
    int a
  , float b
  , msg c
  , account d
  , asset e
  , contract f
  , sig g
  , datetime h
  , void i
) {
  transitionTo(:set);
}

@set
nothing () {
  terminate("bye");
}
