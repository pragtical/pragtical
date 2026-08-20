module example::math;

import std::io;

const int ANSWER = 0x2A;

fn int add(int left, int right)
{
  // Keep this fixture small but cover comments, strings, numbers and symbols.
  int total = left + right + ANSWER;
  io::printf("total: %d\n", total);
  return total;
}
