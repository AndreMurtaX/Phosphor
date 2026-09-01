# Prompt inicial — Phosphor BASIC

Cole o texto abaixo numa sessão nova, com o Claude Code aberto em
`C:\Dev\Phosphor`.
Gerado em 2026-08-31, ao fim da sessão que congelou o Plan9Basic.

---

Vamos começar um projeto novo em C:\Dev\Phosphor — Phosphor BASIC, um
interpretador BASIC embutível escrito em Free Pascal, construído com
Lazarus/FPC. A pasta existe e está vazia. O Lazarus já está instalado nesta
máquina em C:\lazarus, com FPC 3.2.2; só o alvo x86_64-win64 está instalado.

## O QUE É, E O QUE NÃO É

É o sucessor espiritual do Plan9Basic (C:\Dev\Plan9Basic — Delphi/FireMonkey,
MIT, de minha autoria, congelado porque minha licença do RAD Studio vence em
março de 2027). Serve de implementação de referência: leia e copie à vontade.
NÃO é um porte, e não há compromisso nenhum de compatibilidade — várias
decisões de linguagem mudam de propósito, listadas abaixo.

Desktop apenas: Windows e Linux. Sem mobile, sem FireMonkey.

O motor é BIBLIOTECA desde o primeiro dia, e o hospedeiro de console é apenas
o primeiro consumidor dela. A superfície pública precisa ser desenhada assim
desde o início, não retrofitada.

Ordem das fases:

1. Motor + bibliotecas não-gráficas + hospedeiro de console (REPL e execução
   de arquivo).
2. GUI sobre LCL, depois. O motor nunca pode conhecê-la.

## O QUE APROVEITAR DA REFERÊNCIA

Núcleo em C:\Dev\Plan9Basic\engine\: 12.083 linhas em 5 unidades (parser 5802,
exec 3725, UnitUtils 989, basic 792, lexer 775), mais utils\UnitGC.pas (357) e
utils\HandleRegistry.pas (284). Não referencia FireMonkey em lugar nenhum.
tests\NoFmxProbe.dpr já é exatamente a forma alvo: o motor num hospedeiro de
console, sem formulário, sem Application, PrintProc escrevendo em stdout e
InputProc lendo stdin. Toda E/S passa por callbacks do hospedeiro.

Substituições de RTL (Delphi -> Free Pascal), já levantadas:

    System.SysUtils/Classes/Math/StrUtils/Character/DateUtils/SyncObjs/IniFiles
                                -> mesmos nomes sem o prefixo System.
    System.Generics.Collections -> Generics.Collections (temos 3.2.2, serve)
    System.IOUtils              -> FileUtil / LazFileUtils (API diferente)
    System.JSON                 -> fpjson / jsonparser
    System.Net.HttpClient       -> fphttpclient
    System.Zip                  -> zipper
    System.NetEncoding          -> base64 + httpprotocol
    FireDAC (SQLite)            -> SQLdb + sqlite3conn, ou ligar direto na sqlite3

Dois pontos sem equivalente, que pedem decisão e não tradução:

- System.Rtti: o FPC não tem RTTI estendida. UnitUtils.pas usa TRttiContext em
  dois lugares; ver o que fazem e se TypInfo resolve.
- Data.DB e System.UITypes estão no núcleo por acidente (uma função de tipo de
  campo e tipos de cor). No projeto novo não entram.

## DECISÕES DE LINGUAGEM — o que muda em relação ao Plan9Basic

### Tipos

Hoje a VM tem três (`TExprKind = (ekNumber, ekPointer, ekString)`) e a célula de
valor é `record n: Extended; p: Pointer; s: String; end`. Passam a ser cinco:

| sufixo      | tipo                                      |
| ----------- | ----------------------------------------- |
| *(nenhum)*  | numérico — **Double**, não Extended       |
| `$`         | string                                    |
| `%`         | inteiro (NOVO)                            |
| `@`         | handle (era `#`)                          |
| `?`         | lógico (NOVO)                             |

O `#` **não é sufixo de variável**. Fica reservado para número de arquivo na E/S
clássica (`PRINT #1`, `INPUT #1`, `CLOSE #1`), que é o outro significado
tradicional dele no BASIC e um que vamos implementar. Como o sufixo faz parte do
nome nesta linguagem, aceitar `#` como sufixo opcional criaria duas variáveis
distintas (`a` e `a#`) guardando o mesmo tipo — armadilha silenciosa.

O handle migra de `#` para `@`, que carrega "endereço/referência" e é o operador
de endereço do próprio Pascal. Consequência: o separador do formato de registro
NÃO pode mais ser `@` — use `:` ou `|`. No Plan9Basic são ~4.374 assinaturas no
formato `nome@assinatura`; aqui nasce diferente, e essa é a única decisão desta
lista que fica cara se adiada.

O `?` como sufixo lógico lê como pergunta (`done?`, `found?`). Para liberá-lo,
os operadores `?>` e `?<` do Plan9Basic (máximo e mínimo) saem e viram funções
`max()` e `min()`, como em todo outro BASIC.

NÃO haverá tipo BYTE escalar. E/S binária se faz com buffer como handle
(`buf@ = buffer_new(1024)`), que é biblioteca pura, custo zero no parser e na VM.

### Aritmética e promoção

- `int op double` -> **double**, em todas as operações
- `int + - * int` -> **int**
- `int / int` -> **double**. A barra no BASIC é divisão real: `7 / 2` é 3,5
- divisão inteira usa `\`: `7 \ 2` é 3. O `\` está livre — hoje só existe como
  escape dentro de literal de string
- `^` -> **sempre double** (`2 ^ 0.5` tem significado)
- comparação entre tipos diferentes compara como double
- índice de array aceita qualquer numérico e arredonda
- **estouro de inteiro é erro capturável**, não promoção silenciosa para double

### Lógico estrito

Comparação passa a produzir VALOR em qualquer lugar, não só dentro de condição —
hoje `x = 2 > 1` não compila, e isso é uma verruga. `true` e `false` passam a ser
valores utilizáveis. Mantida a regra estrita: valor nu NÃO vale como condição
(`if alive then` continua recusado; use `if alive = 1 then` ou uma expressão
lógica). Isso remove um caso especial do parser em vez de acrescentar.

### Índices

BASE 1 EM TUDO. No Plan9Basic arrays eram base 1 e `mid`/`instr` base 0. Aqui
tudo é base 1, que é a convenção do BASIC. 13 dos 45 programas da suíte mexem
com índice e precisarão de ajuste mecânico.

### Entrada

`INPUT` e `INPUT$` síncronos, como no BASIC padrão. O comando assíncrono de
entrada existia só por causa do mobile e não entra — some junto a máquina de
suspender e retomar a VM em volta dele.

### Erros

`ON ERROR` na linguagem, e bibliotecas que REGISTRAM estado de erro em vez de
abortar. No Plan9Basic há 121 `raise` fatais que matam o programa do usuário; a
linguagem não tem tratamento de erro nenhum. Este é o momento de corrigir.

### Comandos do BASIC padrão a incluir

`PRINT USING`; E/S clássica de arquivo (`OPEN`, `CLOSE`, `PRINT #`, `INPUT #`,
`LINE INPUT #`) convivendo com as funções estilo IOUtils; `LINE INPUT`; `SWAP`;
`RANDOMIZE`; `max()` e `min()`. `DEF FN` fica de fora — já há `function`.

### Codificação

UTF-8 em tudo, declarado explicitamente. As strings do FPC (AnsiString /
UnicodeString / UTF8String, e o LCL em UTF-8) são campo minado e isso precisa
estar resolvido no primeiro dia.

### Regras que permanecem

- O sufixo de tipo faz parte do nome: `a$` e `a` são variáveis diferentes.
- Nomes não diferenciam maiúsculas de minúsculas.
- `sqr()` é raiz quadrada.
- `s$[n]` indexa linha; `s$[[n]]` indexa caractere. Ambos base 1 agora.
- `do while <cond> ... loop`; `function f(n) local a, b ... endfunction`

## BYTECODE EM DISCO — decisões da fase 1, implementação depois

O objetivo, para uma fase futura, é o modelo do Clipper: compilar o script para
bytecode e embalar o bytecode junto com a VM num executável único, que lê o
próprio rabo na partida. É a mesma técnica do PyInstaller, do AutoIt, do
`bun build --compile` e do `deno compile`. PE e ELF ignoram bytes após a última
seção, então o payload vai no fim com um trailer (assinatura mágica, offset,
tamanho, versão de formato, checksum). No Windows o caminho do próprio binário
vem de ParamStr(0); no Linux, /proc/self/exe é mais confiável.

O motor da referência já está quase lá. `TInstr` em exec.pas é:

    TInstr = record
      proc: TExeFunc;    // ponteiro de método
      token: TAsmToken;  // o opcode
      i: Integer;        // offset de string, índice de variável
      n: Extended;       // constante numérica
    end;

Três campos serializam direto. O quarto, `proc`, é DERIVADO — recalculado na
carga por `TokenToFunc(atk)` — e não precisa ser gravado. O formato é, então:
cabeçalho com versão, poço de constantes, vetor de (token, i, n).

NÃO implemente o empacotador na fase 1: enquanto a linguagem se mexe o formato
se mexe junto. Mas tome estas três decisões agora, porque custam zero hoje e
são caras depois:

1. OPCODES COM NÚMERO EXPLÍCITO, atribuídos só por acréscimo, nunca
   reordenados. No Plan9Basic o TAsmToken é um enum em ordem alfabética por
   letra, e acrescentar um opcode no meio desloca o ordinal de todos os
   seguintes — o que é inofensivo enquanto nada fora do processo vê os números,
   e vira quebra silenciosa de formato assim que houver .pbc em disco. Um
   bytecode antigo numa VM nova executaria opcodes trocados sem reclamar.
   A versão de formato precisa ser conferida e recusada em voz alta.
2. No registro da instrução, campos ARMAZENADOS e DERIVADOS separados e
   documentados como tal.
3. O poço de constantes como estrutura explícita e indexável — o campo `i` já
   pressupõe isso.

Com Double fixado e endianness escrita explicitamente (little-endian), o mesmo
.pbc roda no stub do Windows e no do Linux; só o stub é por plataforma.

Um custo honesto a registrar desde já: binário que lê o próprio rabo e executa
payload embutido é a forma clássica de um dropper, e antivírus heurístico marca
isso com entusiasmo — é a queixa número um de quem usa PyInstaller e AutoIt.
Vai acontecer, e a documentação tem de dizer isso em vez de o usuário descobrir
sozinho.

## ARQUITETURA

O registro de funções do Plan9Basic — `Lib.Add('nome:assinatura')` — é o
mecanismo que torna o projeto extensível e fica. Todo pacote de funções se
integra assim.

Console estilizado entra como PACOTE DE FUNÇÕES (`crt_gotoxy`, `crt_color`,
`crt_clear`...), não como comandos da linguagem. O FPC traz `crt`, `video` e
`keyboard` no pacote `rtl-console`, já compilados para win64 nesta máquina. O
`crt` é a unidade do Turbo Pascal; para robustez multiplataforma, `video` +
`keyboard` é a API melhor.

Quando a GUI chegar (fase 2), o desenho combinado é:

- Funções nomeadas amigáveis para as 10 a 15 propriedades mais usadas de cada
  controle — `button_text(b@, "Salvar")` continua lendo como BASIC.
- Por baixo, uma ponte genérica via TypInfo cobrindo TODAS as propriedades
  publicadas, inclusive as que ninguém escreveu invólucro:
  `set(b@, "Font.Size", 14)` / `get(b@, "Width")`. No LCL todo controle desce de
  TPersistent e publica suas propriedades; é o mesmo mecanismo com que o LCL
  grava o próprio `.lfm`. Isso troca ~108 funções por controle por ~8 mais a
  ponte.
- Eventos pela mesma ponte, manipulador identificado por NOME:
  `on(b@, "OnClick", "MinhaFuncao")`.
- Eventos do LCL são ponteiros de método síncronos na thread principal, então a
  marshalling do modelo mobile desaparece.

## O ORÁCULO — comece por aqui

`C:\Dev\Plan9Basic\tests\suite\` tem 45 programas .bas com 1.348 asserções, e
`tests\negative\` tem 15 que o compilador DEVE recusar. Nenhum depende de
plataforma. São o teste de aceitação: quando os 60 passarem (com os ajustes de
base 1, de sufixo `@` e de lógico estrito), a linguagem está correta. A suíte
`tests\gui\` tem outras 4.950 asserções que não se aplicam aqui.

## COMO EU TRABALHO

- Conversamos em português; tudo que entra na árvore — código, comentários,
  documentação, mensagens de commit — vai em inglês.
- Verificar contra a realidade, nunca por suposição. Compilar do zero, rodar,
  medir. Não confiar em código de saída: um passo pode ter sucesso sem ter
  feito nada.
- Uma verificação só vale depois de vista falhando. Toda checagem nova é
  quebrada de propósito uma vez, antes de ser aceita.
- Commits e pushes usam a conta AndreMurtaX.

## PRIMEIRO PASSO

Não escreva o interpretador ainda. Monte o esqueleto e prove que o caminho
existe: projeto Lazarus/FPC que compila em console, a estrutura de pastas que
você propuser, o script de build e o de teste, e um runner capaz de executar um
.bas trivial. Só o alvo win64 está instalado — diga o que falta para o Linux.
Depois disso conversamos sobre a ordem do resto.
