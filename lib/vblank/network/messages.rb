# frozen_string_literal: true

module VBlank
  module Network
    # WHAT MACHINES SAY TO EACH OTHER IN A MATCH, one small value for each thing. A machine sends a
    # message to the room it is in, and the room hands it to every other machine in it; what the
    # receiver is told is an Envelope: who sent it (the sender's number in the room, which is also the
    # sender's player number) and the message.
    #
    # THE ROOM IS EITHER A RELAY OR THE HOST. With a relay each machine is one connection to the relay,
    # which forwards. With a direct connection the host is the room: it takes each message from the
    # machine that sent it, and sends it on to the others. A machine cannot tell the two apart, so one
    # set of messages serves both.
    #
    # The room never plays the game and never reads the buttons in these messages.

    # A message and who sent it. +from+ is the sender's number in the room, stamped by the room and
    # not by the sender, so a machine cannot say it is somebody else.
    Envelope = Data.define(:from, :message)

    # --- before the match: finding out whether two machines can play together ---

    # "I want to play in this match." Sent by a machine that has joined the room to the host, with
    # what it is running: the game's title (for a person), its console, and its digest.
    Join = Data.define(:fingerprint)

    # The host's answer to a Join that is let in. +to+ is the number of the machine it is for. The
    # rest is what every machine must share, and only the host decides: the seed for the game's random
    # numbers, how many passes a person's buttons wait before they count (+input_delay+), how many
    # passes lie between two checkpoints, and how many players the match holds when it is full.
    Welcome = Data.define(:to, :seed, :input_delay, :checkpoint_every, :players)

    # The host's answer to a Join that is not let in, with the reason as a symbol (see Refused) and
    # what the host is running, so the refusal can name it.
    Refuse = Data.define(:to, :reason, :fingerprint)

    # Said by the host to everybody when a machine has been let in, so each can show who is here.
    Joined = Data.define(:player)

    # "The match begins." Said by the host once the match is full. +players+ is the list of player
    # numbers in it. Pass 2, the first pass that reads buttons, comes next.
    Start = Data.define(:players)

    # --- during the match ---

    # What the sender's player will hold on pass +pass+, as one number a bit a button
    # (IR::Buttons). It is sent a few passes before the pass is played (the input delay), which is
    # what gives the network that long to carry it.
    Buttons = Data.define(:pass, :mask)

    # A short number (a CRC-32) of the whole of the sender's game state as it stood after pass
    # +pass+. Machines that run the same game on the same buttons have the same number at the same
    # pass, so a difference is a machine that has gone wrong.
    Checkpoint = Data.define(:pass, :crc)

    # Said by the room, never by a machine: the machine in +from+ has gone. Every message that machine
    # sent has been handed on before this, in order, so every other machine knows the same last pass of
    # its buttons, and the player leaves on the same pass everywhere.
    Left = Data.define
  end
end
