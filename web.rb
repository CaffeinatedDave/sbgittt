require 'sinatra'
require 'mongo'
require 'erb'
require 'dotenv'
require 'open-uri'
require 'erubis'
require 'json'

#set :erb, :escape_html => true

Dotenv.load

include Mongo

use Rack::Logger
set :show_exceptions, :after_handler

helpers do
  def logger
    request.logger
  end
end

$db = Mongo::Client.new(ENV['MONGOLAB_URI'])

def isAllowedUpdate(pass)
  return pass == ENV['passphrase']
end

def getNextSequence(name) 
  ret = $db[:counters].find({"_id" => name}).find_one_and_update(
    { :$inc => { :seq => 1 }},
	  {:return_document => :after}
  )

  ret.seq;
end

not_found do
  status 404
  '{error: "not found"}'
end

before do
  if ENV['debug'] == true
    logger.info request.env.to_s
  end
end

# Orders groups based on games played so far.
#
# For each group, take games played and award wins/loses to each player.
# Order by - total wins, number of sets won, then number of sets lost (to reward 
# playing over inactivity)
#
def orderGroups(tournament)
  groups = []

  tournament[:groups].each do |g| 
    games = tournament[:games].select do |game|
      (g[:participants].include? game[:partA]) && game[:stage] == 1
    end

    logger.info("got " + games.to_s)

    parts = g[:participants].map do |p|
      relevantGames = games.select do |game|
        game[:partA] == p || game[:partB] == p
      end
      wins = relevantGames.select do |game|
        (game[:partA] == p && game[:scoreA] > game[:scoreB]) ||
        (game[:partB] == p && game[:scoreA] < game[:scoreB])
      end
      loses = relevantGames.select do |game|
        (game[:partA] == p && game[:scoreA] < game[:scoreB]) ||
        (game[:partB] == p && game[:scoreA] > game[:scoreB])
      end 
      setsWon = relevantGames.map { |x| x[:partA] == p ? x[:scoreA] : x[:scoreB] }
      setsLost = relevantGames.map { |x| x[:partA] == p ? x[:scoreB] : x[:scoreA] }
        
      {
        :id => p, 
        :wins => wins.count,
        :loses => loses.count,
        :setsWon => setsWon.map(&:to_i).inject(0) {|x,y| x + y},
        :setsLost => setsLost.map(&:to_i).inject(0) {|x,y| x - y}
      }
    end

    newGroup = {
      :name => g[:name],
      :participants => parts.sort_by { |a| [a[:wins], a[:setsWon], a[:setsLost]] }.reverse,
      :games => games
    }

    groups.push(newGroup)
  end

  return groups
end

# This arranges a list of games 1 .. N (where N matches 2^(int)) so that future games are paired 
# in seeding order. As such, if we assume that the favourite seed always wins, each round will only
# contain seeds [1 .. num remaining players]. This can also be used for keeping winners/runners up 
# from any group separate until the final, just by giving them consecutive "seeds" eg 5 and 6 
#
# This should be passed a list of games ordered favourite -> least favourite, according to the "best"
# seeded player - either based on who won the previous rounds (eg if 16 beats 1, 16 may be favourite
# now) or from initial seeding. This is left as a decision for the calling code.
#
# Example: 16 players with matches sorted as follows:
#
# 1 vs 16
#       -- 1 vs 8
# 8 vs 9        |
#               -- 1 vs 4
# 4 vs 13       |      |
#       -- 4 vs 5      |
# 5 vs 12              |
#                      -- 1 vs 2
# 2 vs 15              |
#       -- 2 vs 7      |
# 7 vs 10       |      |
#               -- 2 vs 3
# 3 vs 14       |
#       -- 3 vs 6
# 6 vs 11
#
def arrangeKnockoutGames(gameList)
  take = 1
  while (take < gameList.size)
    newlist = []
    while (!gameList.empty?)
      newlist.push(gameList.shift(take))
      newlist.push(gameList.pop(take))
    end
    gameList = newlist.flatten
    take *= 2
  end

  return gameList
end

get "/list/?" do
  @list = $db[:tournament].find().sort("ezid" => -1)

  erb :list
end

get '/:id?' do
  # Do something cleverer when we have multiple tournaments
  search = {}
  if params[:id] != nil
    search["ezid"] = params[:id].to_i
  end
  @tournament = $db[:tournament].find(search).sort("ezid" => -1).first()

  if @tournament == nil
    not_found
  end

  @groups = orderGroups(@tournament)

  @tournamentName = @tournament[:name]

  games = @tournament[:games].select { |g| g[:stage] != 1 }
  @stages = []
  @stages.push(arrangeKnockoutGames(games.select { |g| g[:stage] == 2 }))
  @stages.push(arrangeKnockoutGames(games.select { |g| g[:stage] == 3 }))
  @stages.push(arrangeKnockoutGames(games.select { |g| g[:stage] == 4 }))

  logger.warn(@stages.to_s)

  erb :index
end

post '/score/?' do
  json = JSON.parse(request.body.read)
  
  ezid = json['id']

  tournament = $db[:tournament].find(:ezid => ezid).first()

  partA = tournament[:participants].find_index(json['partA'])
  partB = tournament[:participants].find_index(json['partB'])

  lastGame = tournament[:games].last
  
  if (partA == nil || partB == nil) 
    # Check we know who the participants are...
    not_found
  else
    scoreA = json['scoreA']
    scoreB = json['scoreB']
    override = json['override'] == nil ? 'N' : json['override']
    # Lowest part number should be first, so switch this if necessary 
    if (partA > partB)
      temp = partA
      partA = partB
      partB = temp

      temp = scoreA
      scoreA = scoreB
      scoreB = temp
    end

    logger.info("Searching for " + partA.to_s + " vs " + partB.to_s)
    found = false
    tournament[:games].map! do |g|
      game = g
      if (g[:stage] == lastGame[:stage] && g[:partA] == partA && g[:partB] == partB)
        if game[:played] == "N" || override == "Y" 
          game[:scoreA] = scoreA.to_i
          game[:scoreB] = scoreB.to_i
          game[:played] = "Y"
          logger.info("Found a score!")
          found = true
        else
          logger.warn("Found, not not overriding")
        end
      end
      game
    end

    if (!found)
      not_found
    end
  end

  $db[:tournament].find(:ezid => tournament[:ezid])
                  .find_one_and_update({"$set" => tournament})
  "Done"
end

post '/start/?' do
  json = JSON.parse(request.body.read)
end
  
post '/progress/?' do
  json = JSON.parse(request.body.read)

  ezid = json['id']

  tournament = $db[:tournament].find({:ezid => ezid}).first()
  lastGame = tournament[:games].last
  stage = lastGame[:stage] + 1

  groups = orderGroups(tournament)
  if (tournament[:games].all? { |g| g[:played] == "Y" })
    if (lastGame[:type] == "G" && tournament[:groups].size >= 4) 
      groups.each_slice(2) do |a,b|
        partA1 = a[:participants][0][:id].to_i
        partA2 = a[:participants][1][:id].to_i
        partB1 = b[:participants][0][:id].to_i
        partB2 = b[:participants][1][:id].to_i
        tournament[:games].push({
          :partA => partA1 < partB2 ? partA1 : partB2, :partB => partA1 > partB2 ? partA1 : partB2,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
        tournament[:games].push({
          :partA => partB1 < partA2 ? partB1 : partA2, :partB => partB1 > partA2 ? partB1 : partA2,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
      end
    elsif (lastGame[:type] == "G" && tournament[:groups].size == 2) 
      groups.each_slice(2) do |a,b|
        partA1 = a[:participants][0][:id].to_i
        partA2 = a[:participants][1][:id].to_i
        partA3 = a[:participants][2][:id].to_i
        partA4 = a[:participants][3][:id].to_i
        partB1 = b[:participants][0][:id].to_i
        partB2 = b[:participants][1][:id].to_i
        partB3 = b[:participants][2][:id].to_i
        partB4 = b[:participants][3][:id].to_i
        tournament[:games].push({
          :partA => partA1 < partB4 ? partA1 : partB4, :partB => partA1 > partB4 ? partA1 : partB4,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
        tournament[:games].push({
          :partA => partA2 < partB3 ? partA2 : partB3, :partB => partA2 > partB3 ? partA2 : partB3,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
        tournament[:games].push({
          :partA => partA3 < partB2 ? partA3 : partB2, :partB => partA3 > partB2 ? partA3 : partB2,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
        tournament[:games].push({
          :partA => partA4 < partB1 ? partA4 : partB1, :partB => partA4 > partB1 ? partA4 : partB1,
          :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
      end
    elsif (lastGame[:type] == "G" && tournament[:groups].size == 1) 
      group = groups.take(1)
      partA1 = group[:participants][0][:id].to_i
      partA2 = group[:participants][1][:id].to_i
      partA3 = group[:participants][2][:id].to_i
      partA4 = group[:participants][3][:id].to_i
      partB1 = group[:participants][4][:id].to_i
      partB2 = group[:participants][5][:id].to_i
      partB3 = group[:participants][6][:id].to_i
      partB4 = group[:participants][7][:id].to_i
      tournament[:games].push({
        :partA => partA1 < partB4 ? partA1 : partB4, :partB => partA1 > partB4 ? partA1 : partB4,
        :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
      tournament[:games].push({
        :partA => partA2 < partB3 ? partA2 : partB3, :partB => partA2 > partB3 ? partA2 : partB3,
        :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
      tournament[:games].push({
        :partA => partA3 < partB2 ? partA3 : partB2, :partB => partA3 > partB2 ? partA3 : partB2,
        :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
      tournament[:games].push({
        :partA => partA4 < partB1 ? partA4 : partB1, :partB => partA4 > partB1 ? partA4 : partB1,
        :scoreA => 0, :scoreB => 0, :stage => stage, :type => "K", :played => "N"})
    else
      games = tournament[:games].select { |g| g[:stage] == lastGame[:stage] }
      if (games.size == 1) 
        tournament[:winner] == games[0][:scoreA] > games[0][:scoreB] ? games[0][:partA] : games[0][:partB]
      else 
        while (!games.empty?)
          gameA = games.shift
          gameB = games.pop

          partA = gameA[:scoreA] > gameA[:scoreB] ? gameA[:partA] : gameA[:partB]
          partB = gameB[:scoreA] > gameB[:scoreB] ? gameB[:partA] : gameB[:partB]

          if (partA > partB) 
            temp = partA
            partA = partB
            partB = temp
          end

          tournament[:games].push({
            :partA => partA, :partB => partB,
            :scoreA => 0, :scoreB => 0,
            :stage => stage, :type => "K", :played => "N"
          })
        end
      end
    end

    $db[:tournament].find(:ezid => tournament[:ezid])
                    .find_one_and_update({"$set" => tournament})
    "Done"
  else
    status 412
    "Not yet"
  end
end 

