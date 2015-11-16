# -*- coding: utf-8 -*-
from cython import boundscheck, wraparound
from numpy cimport ndarray
from numpy import empty, ones
from numpy.linalg import lstsq
from numpy import float64 as float_coord
from libc.math cimport sin, cos, atan2
from libc.stdlib cimport malloc, free

ctypedef unsigned int DTYPE_ui
ctypedef double DTYPE_coord


cdef DTYPE_coord D2R = 0.017453292519943295
cdef DTYPE_coord PI = 3.141592653589793

@wraparound(False)
@boundscheck(False)
def fit_circle_c(
    ndarray[DTYPE_coord] x_vec,
    ndarray[DTYPE_coord] y_vec
    ):
    """
    Fit the circle
    Adapted from ETRACK (KCCMC11)
    """
    cdef DTYPE_ui i_elt, i_start, i_end, nb_elt
    cdef DTYPE_coord x_mean, y_mean, scale, norme_max, center_x, center_y, radius
    cdef DTYPE_coord p_area, c_area, a_err, p_area_incirc, dist_poly
    nb_elt = x_vec.shape[0]

    cdef DTYPE_coord * p_inon_x = <DTYPE_coord * >malloc(nb_elt * sizeof(DTYPE_coord))
    if not p_inon_x:
        raise MemoryError()
    cdef DTYPE_coord * p_inon_y = <DTYPE_coord * >malloc(nb_elt * sizeof(DTYPE_coord))
    if not p_inon_y:
        raise MemoryError()

    x_mean = 0
    y_mean = 0
    
    for i_elt from 0 <= i_elt < nb_elt:
        x_mean += x_vec[i_elt]
        y_mean += y_vec[i_elt]
    y_mean /= nb_elt
    x_mean /= nb_elt
    
    norme = (x_vec - x_mean) ** 2 + (y_vec - y_mean) ** 2
    norme_max = norme.max()
    scale = norme_max ** .5

    # Form matrix equation and solve it
    # Maybe put f4
    datas = ones((nb_elt, 3), dtype='f8')
    for i_elt from 0 <= i_elt < nb_elt:
        datas[i_elt, 0] = 2. * (x_vec[i_elt] - x_mean) / scale
        datas[i_elt, 1] = 2. * (y_vec[i_elt] - y_mean) / scale
        
    (center_x, center_y, radius), _, _, _ = lstsq(datas, norme / norme_max)

    # Unscale data and get circle variables
    radius += center_x ** 2 + center_y ** 2
    radius **= .5
    center_x *= scale
    center_y *= scale
    # radius of fitted circle
    radius *= scale
    # center X-position of fitted circle
    center_x += x_mean
    # center Y-position of fitted circle
    center_y += y_mean

    # area of fitted circle
    c_area = (radius ** 2) * PI
    
    # Find distance between circle center and contour points_inside_poly
    for i_elt from 0 <= i_elt < nb_elt:
        # Find distance between circle center and contour points_inside_poly
        dist_poly = ((x_vec[i_elt] - center_x) ** 2 + (y_vec[i_elt] - center_y) ** 2) ** .5
        # Indices of polygon points outside circle
        # p_inon_? : polygon x or y points inside & on the circle
        if dist_poly > radius:
            p_inon_y[i_elt] = center_y + radius * (y_vec[i_elt] - center_y) / dist_poly
            p_inon_x[i_elt] = center_x - (center_x - x_vec[i_elt]) * (center_y - p_inon_y[i_elt]) / (center_y - y_vec[i_elt])
        else:
            p_inon_x[i_elt] = x_vec[i_elt]
            p_inon_y[i_elt] = y_vec[i_elt]

    # Area of closed contour/polygon enclosed by the circle
    p_area_incirc = 0
    p_area = 0
    for i_elt from 0 <= i_elt < (nb_elt - 1):
        # Indices of polygon points outside circle
        # p_inon_? : polygon x or y points inside & on the circle
        p_area_incirc += p_inon_x[i_elt] * p_inon_y[1 + i_elt] - p_inon_x[i_elt + 1] * p_inon_y[i_elt]
        # Shape test
        # Area and centroid of closed contour/polygon
        p_area += x_vec[i_elt] * y_vec[1 + i_elt] - x_vec[1 + i_elt] * y_vec[i_elt]
    p_area = abs(p_area) * .5
    free(p_inon_x)
    free(p_inon_y)
    p_area_incirc = abs(p_area_incirc) * .5
    
    a_err = (c_area - 2 * p_area_incirc + p_area) * 100. / c_area
    return center_x, center_y, radius, a_err


@wraparound(False)
@boundscheck(False)
cdef is_left(
        DTYPE_coord x_line_0,
        DTYPE_coord y_line_0,
        DTYPE_coord x_line_1,
        DTYPE_coord y_line_1,
        DTYPE_coord x_test,
        DTYPE_coord y_test,
        ):
    """
    http://geomalgorithms.com/a03-_inclusion.html
    isLeft(): tests if a point is Left|On|Right of an infinite line.
    Input:  three points P0, P1, and P2
    Return: >0 for P2 left of the line through P0 and P1
            =0 for P2  on the line
            <0 for P2  right of the line
    See: Algorithm 1 "Area of Triangles and Polygons"
    """
    # Vector product
    cdef DTYPE_coord product
    product = (x_line_1 - x_line_0) * (y_test - y_line_0
        ) - (x_test - x_line_0) * (y_line_1 - y_line_0)
    return product > 0


@wraparound(False)
@boundscheck(False)
def winding_number_poly(
    DTYPE_coord x_test,
    DTYPE_coord y_test,
    ndarray[DTYPE_coord, ndim=2] xy_poly
    ):
    """
    http://geomalgorithms.com/a03-_inclusion.html
    wn_PnPoly(): winding number test for a point in a polygon
          Input:   P = a point,
                   V[] = vertex points of a polygon V[n+1] with V[n]=V[0]
          Return:  wn = the winding number (=0 only when P is outside)
    """
    # the  winding number counter
    cdef int wn = 0

    cdef DTYPE_ui i_elt, nb_elt
    nb_elt = xy_poly.shape[0]

    # loop through all edges of the polygon
    for i_elt from 0 <= i_elt < (nb_elt):
        if i_elt + 1 == nb_elt:
            x_next = xy_poly[0, 0]
            y_next = xy_poly[0, 1]
        else:
            x_next = xy_poly[i_elt + 1, 0]
            y_next = xy_poly[i_elt + 1, 1]
        if xy_poly[i_elt, 1] <= y_test:
            if y_next > y_test:
                if is_left(xy_poly[i_elt, 0],
                           xy_poly[i_elt, 1],
                           x_next,
                           y_next,
                           x_test, y_test
                           ):
                    wn += 1
        else:
            if y_next <= y_test:
                if not is_left(xy_poly[i_elt, 0],
                               xy_poly[i_elt, 1],
                               x_next,
                               y_next,
                               x_test, y_test
                               ):
                    wn -= 1
    return wn

@wraparound(False)
@boundscheck(False)
def distance(
        DTYPE_coord lon0,
        DTYPE_coord lat0,
        DTYPE_coord lon1,
        DTYPE_coord lat1,
        ):

    cdef DTYPE_coord sin_dlat, sin_dlon, cos_lat1, cos_lat2, a_val
    sin_dlat = sin((lat1 - lat0) * 0.5 * D2R)
    sin_dlon = sin((lon1 - lon0) * 0.5 * D2R)
    cos_lat1 = cos(lat0 * D2R)
    cos_lat2 = cos(lat1 * D2R)
    a_val = sin_dlon ** 2 * cos_lat1 * cos_lat2 + sin_dlat ** 2
    return 6371315.0 * 2 * atan2(a_val ** 0.5, (1 - a_val) ** 0.5)


@wraparound(False)
@boundscheck(False)
def distance_vector(
        ndarray[DTYPE_coord] lon0,
        ndarray[DTYPE_coord] lat0,
        ndarray[DTYPE_coord] lon1,
        ndarray[DTYPE_coord] lat1,
        ndarray[DTYPE_coord] dist,
        ):

    cdef DTYPE_coord sin_dlat, sin_dlon, cos_lat1, cos_lat2, a_val
    cdef DTYPE_ui i_elt, nb_elt
    nb_elt = lon0.shape[0]
    for i_elt from 0 <= i_elt < nb_elt:
        sin_dlat = sin((lat1[i_elt] - lat0[i_elt]) * 0.5 * D2R)
        sin_dlon = sin((lon1[i_elt] - lon0[i_elt]) * 0.5 * D2R)
        cos_lat1 = cos(lat0[i_elt] * D2R)
        cos_lat2 = cos(lat1[i_elt] * D2R)
        a_val = sin_dlon ** 2 * cos_lat1 * cos_lat2 + sin_dlat ** 2
        dist[i_elt] = 6371315.0 * 2 * atan2(a_val ** 0.5, (1 - a_val) ** 0.5)


@wraparound(False)
@boundscheck(False)
def distance_matrix(
        ndarray[DTYPE_coord] lon0,
        ndarray[DTYPE_coord] lat0,
        ndarray[DTYPE_coord] lon1,
        ndarray[DTYPE_coord] lat1,
        ndarray[DTYPE_coord, ndim=2] dist,
        ):

    cdef DTYPE_coord sin_dlat, sin_dlon, cos_lat1, cos_lat2, a_val
    cdef DTYPE_ui i_elt0, i_elt1, nb_elt0, nb_elt1
    nb_elt0 = lon0.shape[0]
    nb_elt1 = lon1.shape[0]
    for i_elt0 from 0 <= i_elt0 < nb_elt0:
        for i_elt1 from 0 <= i_elt1 < nb_elt1:
            sin_dlat = sin((lat1[i_elt1] - lat0[i_elt0]) * 0.5 * D2R)
            sin_dlon = sin((lon1[i_elt1] - lon0[i_elt0]) * 0.5 * D2R)
            cos_lat1 = cos(lat0[i_elt0] * D2R)
            cos_lat2 = cos(lat1[i_elt1] * D2R)
            a_val = sin_dlon ** 2 * cos_lat1 * cos_lat2 + sin_dlat ** 2
            dist[i_elt0, i_elt1] = 6371315.0 * 2 * atan2(a_val ** 0.5, (1 - a_val) ** 0.5)


@wraparound(False)
@boundscheck(False)
cdef dist_array_size(
        DTYPE_ui l_i,
        DTYPE_ui nb_c_per_l,
        DTYPE_ui * nb_pt_per_c,
        DTYPE_ui * c_i
        ):
    cdef DTYPE_ui i_elt, i_start, i_end, nb_pts
    i_start = l_i
    i_end = i_start + nb_c_per_l
    nb_pts = 0

    for i_elt from i_start <= i_elt < i_end:
        nb_pts += nb_pt_per_c[i_elt]
    i_contour = c_i[i_start]
    return i_start, i_end, i_contour, i_contour + nb_pts


@wraparound(False)
@boundscheck(False)
def index_from_nearest_path(
        DTYPE_ui level_index,
        ndarray[DTYPE_ui] l_i,
        ndarray[DTYPE_ui] nb_c_per_l,
        ndarray[DTYPE_ui] nb_pt_per_c,
        ndarray[DTYPE_ui] indices_of_first_pts,
        ndarray[DTYPE_coord] x_value,
        ndarray[DTYPE_coord] y_value,
        DTYPE_coord xpt,
        DTYPE_coord ypt,
        ):
    cdef DTYPE_ui i_elt
    cdef DTYPE_ui nearesti, nb_contour

    cdef DTYPE_ui main_start, main_stop, start, end

    nb_contour = nb_c_per_l[level_index]
    if nb_contour == 0:
        return None

    main_start, main_stop, start, end = dist_array_size(
        l_i[level_index],
        nb_contour,
        & nb_pt_per_c[0],
        & indices_of_first_pts[0],
        )

    nearesti = nearest_contour_index(
        & y_value[0],
        & y_value[0],
        xpt,
        ypt,
        start,
        end,
        )

    for i_elt from main_start <= i_elt < main_stop:
        if (indices_of_first_pts[i_elt] -
                indices_of_first_pts[main_start]) > nearesti:
            return i_elt - 1 - main_start
    return i_elt - 1 - main_start


@wraparound(False)
@boundscheck(False)
cdef nearest_contour_index(
        DTYPE_coord * x_value,
        DTYPE_coord * y_value,
        DTYPE_coord xpt,
        DTYPE_coord ypt,
        DTYPE_ui start,
        DTYPE_ui end,
        ):
    cdef DTYPE_ui i_elt, i_ref
    cdef DTYPE_coord dist, dist_ref
    i_ref = start
    dist_ref = dist = (x_value[start] - xpt) ** 2 + (y_value[start] - ypt) ** 2
    for i_elt from start <= i_elt < end:
        dist = (x_value[i_elt] - xpt) ** 2 + (y_value[i_elt] - ypt) ** 2
        if dist < dist_ref:
            dist_ref = dist
            i_ref = i_elt

    return i_ref - start