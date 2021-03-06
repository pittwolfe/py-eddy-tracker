# -*- coding: utf-8 -*-
"""
===========================================================================
This file is part of py-eddy-tracker.

    py-eddy-tracker is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    py-eddy-tracker is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with py-eddy-tracker.  If not, see <http://www.gnu.org/licenses/>.

Copyright (c) 2014-2017 by Evan Mason and Antoine Delepoulle
Email: emason@imedea.uib-csic.es
===========================================================================

tracking.py

Version 3.0.0

===========================================================================

"""
import logging
from glob import glob
from numpy import array, empty, arange, unique, bincount, uint32
from numba import njit
from .observation import EddiesObservations
from ..poly import bbox_intersection, vertice_overlap

logger = logging.getLogger("pet")


class Network:
    __slots__ = ("window", "filenames", "contour_name", "nb_input", "xname", "yname")
    # To be used like a buffer
    DATA = dict()
    FLIST = list()
    NOGROUP = 0

    def __init__(self, input_regex, window=5, intern=False):
        self.window = window
        self.contour_name = EddiesObservations.intern(intern, public_label=True)
        self.xname, self.yname = EddiesObservations.intern(intern,)
        self.filenames = glob(input_regex)
        self.filenames.sort()
        self.nb_input = len(self.filenames)

    def load_contour(self, filename):
        if filename not in self.DATA:
            if len(self.FLIST) > self.window:
                self.DATA.pop(self.FLIST.pop(0))
            e = EddiesObservations.load_file(filename, include_vars=self.contour_name)
            self.DATA[filename] = e[self.xname], e[self.yname]
        return self.DATA[filename]

    def get_group_array(self, results, nb_obs):
        """With a loop on all pair of index, we will label each obs with a group
        number
        """
        nb_obs = array(nb_obs)
        day_start = nb_obs.cumsum() - nb_obs
        gr = empty(nb_obs.sum(), dtype="u4")
        gr[:] = self.NOGROUP

        id_free = 1
        for i, j, ii, ij in results:
            gr_i = gr[slice(day_start[i], day_start[i] + nb_obs[i])]
            gr_j = gr[slice(day_start[j], day_start[j] + nb_obs[j])]
            # obs with no groups
            m = (gr_i[ii] == self.NOGROUP) * (gr_j[ij] == self.NOGROUP)
            nb_new = m.sum()
            gr_i[ii[m]] = gr_j[ij[m]] = arange(id_free, id_free + nb_new)
            id_free += nb_new
            # associate obs with no group with obs with group
            m = (gr_i[ii] != self.NOGROUP) * (gr_j[ij] == self.NOGROUP)
            gr_j[ij[m]] = gr_i[ii[m]]
            m = (gr_i[ii] == self.NOGROUP) * (gr_j[ij] != self.NOGROUP)
            gr_i[ii[m]] = gr_j[ij[m]]
            # case where 2 obs have a different group
            m = gr_i[ii] != gr_j[ij]
            if m.any():
                # Merge of group, ref over etu
                for i_, j_ in zip(ii[m], ij[m]):
                    gr_i_, gr_j_ = gr_i[i_], gr_j[j_]
                    gr[gr == gr_i_] = gr_j_
        return gr

    def group_observations(self, **kwargs):
        results, nb_obs = list(), list()
        # To display print only in INFO
        display_iteration = logger.getEffectiveLevel() == logging.INFO
        for i, filename in enumerate(self.filenames):
            if display_iteration:
                print(f"{filename} compared to {self.window} next", end="\r")
            # Load observations with function to buffered observations
            xi, yi = self.load_contour(filename)
            # Append number of observations by filename
            nb_obs.append(xi.shape[0])
            for j in range(i + 1, min(self.window + i + 1, self.nb_input)):
                xj, yj = self.load_contour(self.filenames[j])
                ii, ij = bbox_intersection(xi, yi, xj, yj)
                m = vertice_overlap(xi[ii], yi[ii], xj[ij], yj[ij], **kwargs) > 0.2
                results.append((i, j, ii[m], ij[m]))
        if display_iteration:
            print()

        gr = self.get_group_array(results, nb_obs)
        logger.info(
            f"{(gr == self.NOGROUP).sum()} alone / {len(gr)} obs, {len(unique(gr))} groups"
        )

    def save(self, output_filename):
        new_i = get_next_index(gr)
        nb = gr.shape[0]
        dtype = list()
        with Dataset(output_filename, "w") as h_out:
            with Dataset(self.filenames[0]) as h_model:
                for name, dim in h_model.dimensions.items():
                    h_out.createDimension(name, len(dim) if name != "obs" else nb)
                v = h_out.createVariable(
                    "track", "u4", ("obs",), True, chunksizes=(min(250000, nb),)
                )
                d = v[:].copy()
                d[new_i] = gr
                v[:] = d
                for k in h_model.ncattrs():
                    h_out.setncattr(k, h_model.getncattr(k))
                for name, v in h_model.variables.items():
                    dtype.append(
                        (
                            name,
                            (v.datatype, 50) if "NbSample" in v.dimensions else v.datatype,
                        )
                    )
                    new_v = h_out.createVariable(
                        name,
                        v.datatype,
                        v.dimensions,
                        True,
                        chunksizes=(min(25000, nb), 50)
                        if "NbSample" in v.dimensions
                        else (min(250000, nb),),
                    )
                    for k in v.ncattrs():
                        if k in ("min", "max",):
                            continue
                        new_v.setncattr(k, v.getncattr(k))
            data = empty(nb, dtype)
            i = 0
            debug_active = logger.getEffectiveLevel() == logging.DEBUG
            for filename in self.filenames:
                if debug_active:
                    print(f"Load {filename} to copy", end="\r")
                with Dataset(filename) as h_in:
                    stop = i + len(h_in.dimensions["obs"])
                    sl = slice(i, stop)
                    for name, _ in dtype:
                        v = h_in.variables[name]
                        v.set_auto_maskandscale(False)
                        data[name][new_i[sl]] = v[:]
                    i = stop
            if debug_active:
                print()
            for name, _ in dtype:
                v = h_out.variables[name]
                v.set_auto_maskandscale(False)
                v[:] = data[name]


@njit(cache=True)
def get_next_index(gr):
    """Return for each obs index the new position to join all group
    """
    nb_obs_gr = bincount(gr)
    i_gr = nb_obs_gr.cumsum() - nb_obs_gr
    new_index = empty(gr.shape, dtype=uint32)
    for i, g in enumerate(gr):
        new_index[i] = i_gr[g]
        i_gr[g] += 1
    return new_index
