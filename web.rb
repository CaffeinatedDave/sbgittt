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

helpers do
  def logger
    request.logger
  end
end

$db = Mongo::Client.new(ENV['MONGOLAB_URI'])

def getNextSequence(name) 
  ret = $db[:counters].find({"_id" => name}).find_one_and_update(
    { :$inc => { :seq => 1 }},
	  {:return_document => :after}
  )

  ret.seq;
end

before do
  if ENV['debug'] == true
    logger.info request.env.to_s
  end
end

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

get '/' do
  # Do something cleverer when we have multiple tournaments
  @tournament = $db[:tournament].find().first()

  @groups = orderGroups(@tournament)

  erb :index
end

post '/score/?' do
  json = JSON.parse(request.body.read)
  
  tournament = $db[:tournament].find().first()

  partA = tournament[:participants].find_index(json['partA'])
  partB = tournament[:participants].find_index(json['partB'])

  lastGame = tournament[:games].last
  
  if (partA == nil || partB == nil) 
    # Check we know who the participants are...
    not_found
  else
    scoreA = json['scoreA']
    scoreB = json['scoreB']
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
      if (g[:round] == lastGame[:round] && g[:partA] == partA && g[:partB] == partB)
        game[:scoreA] = scoreA.to_i
        game[:scoreB] = scoreB.to_i
        game[:played] = "Y"
        logger.info("Found a score!")
        found = true
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

post '/progress/?' do
  tournament = $db[:tournament].find().first()

  if (tournament[:games].all? { |g| g[:played] == "Y" })
    lastGame = tournament[:games].last
    round = lastGame[:round] + 1
    if (game[:type] == "G") 
      orderGroups(tournament).each_slice(2) do |a,b|
        #TODO - actually add more games
      end
    else
      #TODO - pair off winners
    end
  else
    not_yet
  end
end 

not_found do
  status 404
  '{error: "not found"}'
end

not_yet do
  status 412
  '{error: "not yet.."}'
end

after do
  # Close the connection after the request is done so that we don't
  # deplete the ActiveRecord connection pool.

  # Don't think this is needed for mongo...
end
