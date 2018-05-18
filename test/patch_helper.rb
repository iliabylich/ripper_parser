require 'parser/ruby25'
require 'ripper_lexer'

module Parser
  dedenter = Lexer::Dedenter

  remove_const(:Lexer)
  Lexer = RipperLexer
  Lexer::Dedenter = dedenter

  remove_const(:Ruby25)
  Ruby25 = Ruby25WithRipperLexer
end
