gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo.png"

-- Couleurs PROVISOIRES : a remplacer par la charte de l'Espace culturel
local FOND     = {0.08, 0.09, 0.12}
local FOND_UNE = {0.12, 0.14, 0.17}
local TRAIT    = {0.15, 0.17, 0.21}
local ACCENT   = {0.97, 0.58, 0.12}
local TEXTE    = {1.00, 1.00, 1.00}
local TEXTE_2  = {0.73, 0.75, 0.80}

local function texture(c)
  return resource.create_colored_texture(c[1], c[2], c[3], 1)
end

local tex_fond     = texture(FOND)
local tex_fond_une = texture(FOND_UNE)
local tex_trait    = texture(TRAIT)
local tex_accent   = texture(ACCENT)

local LIGNES_VISIBLES = 10
local DUREE_UNE_FIXE  = 8       -- secondes par evenement a la une quand la liste ne defile pas
local VITESSES = {               -- lignes par seconde
  ["1"] = 0.06, ["2"] = 0.10, ["3"] = 0.15, ["4"] = 0.22,
}

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local titre    = "Strasbourg"
local vitesse  = VITESSES["2"]
local rotation = 90

util.json_watch("config.json", function(config)
  titre    = config.titre or titre
  vitesse  = VITESSES[tostring(config.vitesse)] or VITESSES["2"]
  rotation = tonumber(config.rotation) or 90
end)

-- Agenda ecrit par le service (agenda.json), absent au premier demarrage
local evenements = {}
local depart = sys.now()        -- debut du defilement, remis a zero a chaque mise a jour
local cache_textes = {}

local function lire_agenda()
  local ok, donnees = pcall(function()
    return json.decode(resource.load_file "agenda.json")
  end)
  if ok and type(donnees) == "table" and type(donnees.evenements) == "table" then
    evenements = donnees.evenements
    depart = sys.now()
    cache_textes = {}
  end
end

node.event("content_update", function(fichier)
  if fichier == "agenda.json" then lire_agenda() end
end)
lire_agenda()

-- Affiches : seules celles a l'ecran restent chargees en memoire
local affiches = {}

local function affiche(nom)
  if type(nom) ~= "string" then return nil end
  if not affiches[nom] then
    local ok, img = pcall(resource.load_image, nom)
    if not ok then return nil end
    affiches[nom] = img
  end
  return affiches[nom]
end

local function garder_affiches(utiles)
  for nom, img in pairs(affiches) do
    if not utiles[nom] then
      img:dispose()
      affiches[nom] = nil
    end
  end
end

------------------------------------------------------------------------
-- Texte
------------------------------------------------------------------------

local function ecrire(texte, x, y, taille, c)
  font:write(x, y, texte, taille, c[1], c[2], c[3], 1)
end

-- Raccourcit le texte avec "..." pour qu'il tienne dans la largeur
local function tronquer(texte, taille, largeur)
  local cle = texte .. "|" .. taille .. "|" .. largeur
  if cache_textes[cle] then return cache_textes[cle] end
  local r = texte
  if font:width(r, taille) > largeur then
    while #r > 0 and font:width(r .. "...", taille) > largeur do
      r = r:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")   -- retire un caractere UTF-8
    end
    r = r .. "..."
  end
  cache_textes[cle] = r
  return r
end

-- Decoupe le texte en "max" lignes au plus, la derniere raccourcie si besoin
local function couper(texte, taille, largeur, max)
  local lignes, ligne = {}, ""
  for mot in texte:gmatch("%S+") do
    local essai = ligne == "" and mot or ligne .. " " .. mot
    if ligne ~= "" and font:width(essai, taille) > largeur then
      lignes[#lignes + 1] = ligne
      ligne = mot
    else
      ligne = essai
    end
  end
  if ligne ~= "" then lignes[#lignes + 1] = ligne end
  if #lignes > max then
    lignes[max] = table.concat(lignes, " ", max)
    for i = #lignes, max + 1, -1 do lignes[i] = nil end
  end
  for i, l in ipairs(lignes) do lignes[i] = tronquer(l, taille, largeur) end
  return lignes
end

local function lieu(e)
  local t = e.salle or ""
  if e.ville and e.ville ~= "" then t = t .. " - " .. e.ville end
  return t
end

------------------------------------------------------------------------
-- Zones de l'ecran
------------------------------------------------------------------------

local function entete(W, H, h)
  tex_fond:draw(0, 0, W, h)
  local p = W * 0.05
  ecrire("AGENDA CULTUREL", p, h * 0.20, H * 0.016, ACCENT)
  ecrire(tronquer(titre, H * 0.042, W - 2 * p), p, h * 0.40, H * 0.042, TEXTE)
  tex_accent:draw(0, h - H * 0.004, W, h)
end

local function une(e, W, H, y0, h)
  tex_fond_une:draw(0, y0, W, y0 + h)
  if not e then return end

  -- Affiche a gauche, dans un cadre 3:2
  local p  = W * 0.04
  local bw = W * 0.46
  local bh = math.min(bw / 1.5, h - 2 * p)
  local by = y0 + (h - bh) / 2
  tex_trait:draw(p, by, p + bw, by + bh)
  local img = affiche(e.affiche)
  if img and img:state() == "loaded" then
    local iw, ih = img:size()
    local f = math.min(bw / iw, bh / ih)
    local dw, dh = iw * f, ih * f
    img:draw(p + (bw - dw) / 2, by + (bh - dh) / 2, p + (bw + dw) / 2, by + (bh + dh) / 2)
  end

  -- Textes a droite
  local x = p + bw + p
  local larg = W - x - p
  local t_tag, t_titre, t_info = H * 0.014, H * 0.022, H * 0.016
  local y = by

  local tag = "À LA UNE"
  local pad = t_tag * 0.4
  tex_accent:draw(x, y, x + font:width(tag, t_tag) + 2 * pad, y + t_tag + 2 * pad)
  ecrire(tag, x + pad, y + pad, t_tag, FOND)
  y = y + t_tag + 2 * pad + H * 0.010

  for _, l in ipairs(couper(e.titre or "", t_titre, larg, 3)) do
    ecrire(l, x, y, t_titre, TEXTE)
    y = y + t_titre * 1.15
  end
  y = y + H * 0.006
  for _, l in ipairs(couper(lieu(e), t_info, larg, 2)) do
    ecrire(l, x, y, t_info, TEXTE_2)
    y = y + t_info * 1.2
  end
  y = y + H * 0.006
  local quand = e.jour or ""
  if e.heure and e.heure ~= "" then quand = quand .. " à " .. e.heure end
  ecrire(tronquer(quand, t_info * 1.1, larg), x, y, t_info * 1.1, ACCENT)
  if type(e.fin) == "string" then
    y = y + t_info * 1.35
    ecrire(tronquer("jusqu'au " .. e.fin, t_info, larg), x, y, t_info, TEXTE_2)
  end
end

local function ligne(e, W, y, h)
  local p = W * 0.04
  local col = W * 0.20
  local t1, t2 = h * 0.27, h * 0.22

  ecrire(e.jour or "", p, y + h * 0.20, t1, ACCENT)
  ecrire(e.heure or "", p, y + h * 0.55, t2, TEXTE_2)

  local x = p + col
  local larg = W - x - p
  ecrire(tronquer(e.titre or "", t1, larg), x, y + h * 0.20, t1, TEXTE)
  local sous = lieu(e)
  if type(e.fin) == "string" then sous = sous .. " - jusqu'au " .. e.fin end
  ecrire(tronquer(sous, t2, larg), x, y + h * 0.55, t2, TEXTE_2)

  tex_trait:draw(p, y + h - 2, W - p, y + h)
end

local function pied(W, H, y0)
  tex_fond:draw(0, y0, W, H)
  tex_trait:draw(0, y0, W, y0 + 2)
  local h = H - y0
  local lh = h * 0.50
  local iw, ih = logo:size()
  local lw = lh * iw / ih
  local texte = "ESPACE CULTUREL"
  local t = h * 0.30
  local total = lw + h * 0.25 + font:width(texte, t)
  local x = (W - total) / 2
  logo:draw(x, y0 + (h - lh) / 2, x + lw, y0 + (h + lh) / 2)
  ecrire(texte, x + lw + h * 0.25, y0 + (h - t) / 2, t, TEXTE)
end

------------------------------------------------------------------------

function node.render()
  gl.clear(FOND[1], FOND[2], FOND[3], 1)

  -- Ecran en portrait : on tourne le dessin
  local W, H = WIDTH, HEIGHT
  if rotation == 90 or rotation == 270 then W, H = HEIGHT, WIDTH end
  gl.translate(WIDTH / 2, HEIGHT / 2)
  gl.rotate(rotation, 0, 0, 1)
  gl.translate(-W / 2, -H / 2)

  local h_entete, h_une, h_pied = H * 0.09, H * 0.22, H * 0.07
  local y_liste = h_entete + h_une
  local h_ligne = (H - h_pied - y_liste) / LIGNES_VISIBLES

  local n = #evenements
  if n == 0 then
    entete(W, H, h_entete)
    local t = H * 0.02
    local msg = "Chargement de l'agenda..."
    ecrire(msg, (W - font:width(msg, t)) / 2, H * 0.45, t, TEXTE_2)
    pied(W, H, H - h_pied)
    return
  end

  -- Defilement continu de la liste ; l'evenement arrive en haut passe a la une
  local premier, decalage, i_une
  local ecoule = sys.now() - depart
  if n > LIGNES_VISIBLES then
    local y = (ecoule * vitesse * h_ligne) % (n * h_ligne)
    premier  = math.floor(y / h_ligne)
    decalage = y - premier * h_ligne
    i_une    = math.floor(y / h_ligne + 0.5) % n
  else
    premier, decalage = 0, 0
    i_une = math.floor(ecoule / DUREE_UNE_FIXE) % n
  end

  local a_montrer = math.min(n, LIGNES_VISIBLES + 1)
  for k = 0, a_montrer - 1 do
    ligne(evenements[(premier + k) % n + 1], W, y_liste + k * h_ligne - decalage, h_ligne)
  end

  -- En-tete, une et pied recouvrent les lignes qui sortent de la liste
  entete(W, H, h_entete)
  local e = evenements[i_une + 1]
  local suivant = evenements[(i_une + 1) % n + 1]
  une(e, W, H, h_entete, h_une)
  pied(W, H, H - h_pied)

  -- L'affiche suivante est chargee a l'avance
  local utiles = {}
  if type(e.affiche) == "string" then utiles[e.affiche] = true end
  if type(suivant.affiche) == "string" then
    utiles[suivant.affiche] = true
    affiche(suivant.affiche)
  end
  garder_affiches(utiles)
end
