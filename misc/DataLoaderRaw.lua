--[[
Same as DataLoader but only requires a folder of images.
Does not have an h5 dependency.
Only used at test time.
]]--

local utils = require 'misc.utils'
local matio = require 'matio'
require 'lfs'
require 'image'

local DataLoaderRaw = torch.class('DataLoaderRaw')

function DataLoaderRaw:__init(opt)
  --- dataLoader of about 100 texture images
  print('DataLoaderRaw loading images from folder: ', opt.folder_path)

  self.files = {}
  self.ids = {}
  -- read in all the filenames from the folder
  print('listing all images in directory ' .. opt.folder_path)
  local function isImage(f)
    local supportedExt = {'.jpg','.JPG','.jpeg','.JPEG','.png','.PNG','.ppm','.PPM'}
    for _,ext in pairs(supportedExt) do
      local _, end_idx =  f:find(ext)
      if end_idx and end_idx == f:len() then
        return true
      end
    end
    return false
  end
  local n = 1
  for file in paths.files(opt.folder_path, isImage) do
    local fullpath = path.join(opt.folder_path, file)
    table.insert(self.files, fullpath)
    table.insert(self.ids, tostring(n)) -- just order them sequentially
    n=n+1
  end

  self.N = #self.files
  print('DataLoaderRaw found ' .. self.N .. ' images')

  self.images = {}
  if opt.color > 0 then self.nChannels = 3 else self.nChannels = 1 end

  for i=1,self.N do
    local img = image.load(self.files[i], self.nChannels, 'float')
    if img:dim() == 2 then img = img:resize(1, img:size(1), img:size(2)) end
    if img:size(2) > opt.img_size or img:size(3) > opt.img_size then
      local factor = math.max(opt.img_size/img:size(2), opt.img_size/img:size(3))
      img = image.scale(img, math.ceil(img:size(2)*factor-0.5), math.ceil(img:size(3)*factor-0.5))
    end
    if self.nChannels == 3 then
      img = image.rgb2yuv(img)
      self.images[i] = img
    else
      self.images[i] = img:add(opt.shift)
    end
  end
  if self.nChannels == 3 then
    self:whitening()
  end
  self.iterator = 1
end

function DataLoaderRaw:whitening()
  -- calculate the mean and covariance matrix of the whole dataset
  local ps = self.nChannels
  local imgs
  for idx, img in pairs(self.images) do
    if imgs == nil then
      imgs = img:clone():view(ps, -1)
    else
      imgs = torch.cat(imgs, img:view(ps, -1))
    end
  end
  self.mu = torch.mean(imgs, 2)
  --print(self.mu)
  imgs = torch.add(imgs, -1, torch.repeatTensor(self.mu, 1, imgs:size(2)))
  local sigma = torch.mm(imgs, imgs:transpose(1, 2)):div(imgs:size(2))
  --print(sigma)
  local U, S, V = torch.svd(sigma)
  --print(U, S, V)
  local affine = S:add(1e-8):sqrt():cinv()*0.2
  local affine_inv = torch.ones(ps):cdiv(affine)
  affine = torch.diag(affine)
  affine_inv = torch.diag(affine_inv)
  --print(affine)
  affine = torch.mm(U, torch.mm(affine, U:transpose(1,2)))
  affine_inv = torch.mm(torch.mm(U, affine_inv), U:transpose(1,2))
  --print(affine)
  self.affine = affine
  self.affine_inv = affine_inv
  local I = torch.mm(affine, affine_inv)
  print(I)

  -- transform every image
  for idx, img in pairs(self.images) do
    local h = img:size(2)
    local w = img:size(3)
    img = torch.add(img:view(ps, -1), -1, torch.repeatTensor(self.mu, 1, h*w))
    img = torch.mm(self.affine, img)
    self.images[idx] = img:view(ps, h, w)
    -- for debugging
    local s = torch.mm(img, img:transpose(1,2)):div(h*w)
    print('---------DataLoader-------------')
    print(s)
    print(torch.max(img[1]))
    print(torch.min(img[1]))
    print(torch.max(img[2]))
    print(torch.min(img[2]))
    print(torch.max(img[3]))
    print(torch.min(img[3]))
  end

end

function DataLoaderRaw:resetIterator()
  self.iterator = 1
end

function DataLoaderRaw:getChannelSize()
  return self.nChannels
end

function DataLoaderRaw:getChannelScale()
  return {mu = self.mu, affine = self.affine_inv}
end

--[[
  Returns a batch of data:
  - X (N,3,256,256) containing the images as uint8 ByteTensor
  - info table of length N, containing additional information
  The data is iterated linearly in order
--]]
function DataLoaderRaw:getBatch(opt)
  -- may possibly preprocess the image by resizing, cropping
  local crop_size = utils.getopt(opt, 'crop_size', 64)
  local batch_size = utils.getopt(opt, 'batch_size', 4)

  local images = torch.Tensor(batch_size, self.nChannels, crop_size, crop_size)
  --local infos = {}

  for i=1,batch_size do
    local im = self.images[self.iterator]
    self.iterator = self.iterator + 1
    if self.iterator > self.N then self.iterator = 1 end

    local h = torch.random(1, im:size(2)-crop_size+1)
    local w = torch.random(1, im:size(3)-crop_size+1)
    --h = (im:size(2)-crop_size)/2+1
    --w = (im:size(3)-crop_size)/2+1
    -- put the patch in the center.
    images[i] = im[{{}, {h, h+crop_size-1}, {w, w+crop_size-1}}]
    -- and record associated info as well
    -- local info_struct = {}
    -- info_struct.id = self.ids[ri]
    -- info_struct.file_path = self.files[ri]
    -- table.insert(infos, info_struct)
  end

  if opt.gpu >= 0 then
    images = images:cuda()
  end

  return images
end
